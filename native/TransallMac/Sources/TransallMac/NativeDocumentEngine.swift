import Combine
import Foundation

@MainActor
final class NativeDocumentEngine: ObservableObject {
  typealias JobPersister = (JobResponse, URL) throws -> Void

  enum State: Equatable {
    case starting
    case running
    case failed(String)

    var label: String {
      switch self {
      case .starting: "正在准备原生引擎"
      case .running: "原生引擎已就绪"
      case .failed: "原生引擎不可用"
      }
    }
  }

  @Published private(set) var state: State = .starting
  @Published private(set) var serviceLog: [String] = []

  private var jobs: [String: JobResponse] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  private var deletingJobs: Set<String> = []
  private var dataDirectory: URL?
  private let dataDirectoryOverride: URL?
  private let jobPersister: JobPersister
  private let credentialStore: any ProviderCredentialStoring
  private var isTerminating = false

  init(
    dataDirectoryOverride: URL? = nil, jobPersister: JobPersister? = nil,
    credentialStore: any ProviderCredentialStoring = ProviderCredentialStore.shared
  ) {
    self.dataDirectoryOverride = dataDirectoryOverride
    self.credentialStore = credentialStore
    self.jobPersister =
      jobPersister ?? { job, directory in
        try Self.persistJob(job, in: directory)
      }
  }

  func start() async {
    state = .starting
    do {
      let override = dataDirectoryOverride
      let preparation = Task.detached(priority: .utility) {
        try Self.prepareDataDirectory(override: override)
      }
      let prepared = try await withTaskCancellationHandler(
        operation: { try await preparation.value },
        onCancel: { preparation.cancel() })
      dataDirectory = prepared.directory
      prepared.warnings.forEach(appendLog)
      state = .running
      appendLog("PDFKit、Core Graphics 和 Vision 已就绪。")
    } catch is CancellationError {
      return
    } catch {
      state = .failed(error.localizedDescription)
      appendLog(error.localizedDescription)
    }
  }

  func prepareForTermination() {
    isTerminating = true
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
  }

  func capabilities() -> CapabilitiesResponse { NativeCapabilities.response }

  func diagnostics() -> DiagnosticsResponse {
    NativeCapabilities.diagnostics(providerConfigured: credentialStatus(logErrors: true))
  }

  func providers() -> ProvidersResponse {
    NativeCapabilities.providers(configured: credentialStatus(logErrors: false))
  }

  func applyCredentialChanges() async -> String {
    "翻译服务配置已更新。"
  }

  func preflight(
    route: RouteDefinition, files: [SelectedDocument], options: JobOptions
  ) -> PreflightResponse {
    var blocking: [PreflightIssue] = []
    var warnings: [PreflightIssue] = []
    let total = files.reduce(Int64.zero) { $0 + $1.size }
    if files.isEmpty {
      blocking.append(issue("missing_files", "请选择至少一个文件。"))
    } else if total > Int64(NativeCapabilities.uploadLimitBytes) {
      blocking.append(issue("upload_too_large", "所选文件总计超过 250 MB。"))
    }

    let allowed = allowedExtensions(for: route.source)
    for file in files where file.size == 0 {
      blocking.append(
        issue("empty_file", "\(file.name) 是空文件。", hint: "请选择包含内容的文件。"))
    }
    for file in files where !allowed.contains(file.url.pathExtension.lowercased()) {
      blocking.append(
        issue(
          "invalid_file_type", "\(file.name) 不符合此路径的输入格式。",
          hint: "请选择：\(allowed.sorted().joined(separator: ", "))"))
    }
    if route.kind == "pdf_edit", options.editAction == "merge", files.count < 2 {
      blocking.append(issue("merge_requires_files", "合并 PDF 至少需要两个文件。"))
    }
    if route.kind == "pdf_edit", options.editAction != "merge", files.count != 1 {
      blocking.append(
        issue(
          "single_file_required", "编辑单个 PDF 时只能选择一个文件。",
          hint: "如需合并多个 PDF，请选择“按列表顺序合并 PDF”。"))
    }
    if route.kind == "pdf_translate" {
      if files.count != 1 {
        blocking.append(
          issue(
            "single_file_required", "PDF 翻译每次只能处理一个文件。",
            hint: "请移除多余文件后再开始翻译。"))
      }
      if !["deepseek", "openai"].contains(options.provider) {
        blocking.append(
          issue(
            "invalid_provider", "翻译服务无效。",
            hint: "请在翻译选项中重新选择 DeepSeek 或 OpenAI。"))
      }
      if options.glossary.count > TranslationService.maximumGlossaryCharacters {
        blocking.append(
          issue(
            "glossary_too_large",
            "术语表超过 \(TranslationService.maximumGlossaryCharacters) 个字符。",
            hint: "请删除不相关术语后再试。"))
      }
      if let credential = ProviderCredential(rawValue: options.provider) {
        do {
          let key = try credentialStore.value(for: credential)
          if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocking.append(
              issue(
                "provider_not_configured",
                "\(credential.displayName) API Key 尚未配置。",
                hint: "打开 Transall 设置并保存 API Key。"))
          }
        } catch {
          blocking.append(
            issue(
              "provider_keychain_unavailable", "无法从 macOS 钥匙串读取翻译 API Key。",
              hint: error.localizedDescription))
        }
      }
      warnings.append(
        issue(
          "remote_processing", "翻译时，提取出的文档文字会发送给所选服务商。",
          hint: "PDF 原文件不会上传。"))
    }
    return PreflightResponse(
      ok: blocking.isEmpty, blockingIssues: blocking, warnings: warnings,
      requirements: route.requirements)
  }

  func createJob(
    route: RouteDefinition, files: [SelectedDocument], options: JobOptions
  ) async throws -> JobResponse {
    guard state == .running, let dataDirectory else {
      throw NativeDocumentError.processing("原生文档引擎尚未就绪。")
    }
    let id = UUID().uuidString.lowercased()
    let directory = dataDirectory.appendingPathComponent("Jobs/\(id)", isDirectory: true)
    let inputDirectory = directory.appendingPathComponent("Input", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
      let copiedInputs = try await Self.copyInputs(files, to: inputDirectory)

      let now = ISO8601DateFormatter().string(from: Date())
      let job = JobResponse(
        id: id, kind: route.kind, status: "queued", inputs: files.map(\.name), createdAt: now,
        updatedAt: now, output: nil, error: nil, stage: "queued", message: "任务已进入队列。",
        errorCode: nil, errorHint: nil, retryable: false, progress: 0,
        cancelRequested: false, logs: ["已将输入副本保存到应用沙盒。"])
      let metadata = NativeJobMetadata(
        route: route, options: options, inputNames: copiedInputs.map(\.lastPathComponent))
      jobs[id] = job
      try jobPersister(job, directory)
      try persistMetadata(metadata, in: directory)
      launch(jobID: id, metadata: metadata, directory: directory)
      return job
    } catch {
      jobs[id] = nil
      tasks[id]?.cancel()
      tasks[id] = nil
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  func job(id: String) throws -> JobResponse {
    if let job = jobs[id] { return job }
    let directory = try jobDirectory(id)
    let job: JobResponse = try load("job.json", from: directory)
    jobs[id] = job
    if job.isRunning, tasks[id] == nil {
      let metadata: NativeJobMetadata = try load("metadata.json", from: directory)
      if let recovered = recoveredState(job, metadata: metadata, directory: directory) {
        jobs[id] = recovered
        do {
          try jobPersister(recovered, directory)
        } catch {
          jobs[id] = appendingLog(
            "警告：任务恢复状态未能保存：\(error.localizedDescription)", to: recovered)
          appendPersistenceWarning(jobID: id, action: "保存恢复状态", error: error)
        }
      } else {
        appendLog("正在恢复上次未完成的本地任务 \(id.prefix(8))。")
        launch(jobID: id, metadata: metadata, directory: directory)
      }
    }
    return jobs[id] ?? job
  }

  func cancelJob(id: String) throws -> JobResponse {
    guard var job = try? job(id: id), job.isRunning else {
      throw NativeDocumentError.processing("任务不存在或已经结束。")
    }
    job = replacing(
      job, status: "cancelled", stage: "cancelled", message: "任务已取消。", progress: job.progress,
      cancelRequested: true, logs: job.logs + ["已收到取消请求。"])
    tasks[id]?.cancel()
    tasks[id] = nil
    let directory = try jobDirectory(id)
    do {
      try jobPersister(job, directory)
      jobs[id] = job
    } catch {
      job = persistenceFailure(
        from: job, action: "任务已停止，但无法保存取消状态", error: error,
        cancelRequested: true)
      jobs[id] = job
      appendPersistenceWarning(jobID: id, action: "保存取消状态", error: error)
    }
    return job
  }

  func deleteJob(id: String) async throws {
    let directory = try jobDirectory(id)
    if tasks[id] != nil || jobs[id]?.isRunning == true {
      throw NativeDocumentError.processing("正在运行的任务不能删除。")
    }
    if jobs[id] == nil, let persisted: JobResponse = try? load("job.json", from: directory),
      persisted.isRunning
    {
      throw NativeDocumentError.processing("正在运行的任务不能删除。")
    }
    guard deletingJobs.insert(id).inserted else {
      throw NativeDocumentError.processing("任务数据正在删除。")
    }
    defer { deletingJobs.remove(id) }

    let deletion = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      if FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.removeItem(at: directory)
      }
    }
    try await withTaskCancellationHandler(
      operation: { try await deletion.value },
      onCancel: { deletion.cancel() })

    jobs[id] = nil
  }

  func download(jobID: String, to destination: URL) async throws {
    let job = try job(id: jobID)
    guard job.status == "done", let output = job.output else {
      throw NativeDocumentError.processing("任务还没有可保存的结果。")
    }
    let source = try jobDirectory(jobID).appendingPathComponent(output)
    let transfer = Task.detached(priority: .userInitiated) {
      let accessing = destination.startAccessingSecurityScopedResource()
      defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
      try AtomicResultSaver.copyReplacing(source: source, destination: destination)
    }
    try await withTaskCancellationHandler(
      operation: { try await transfer.value },
      onCancel: { transfer.cancel() })
  }

  func previewPages(jobID: String) async throws -> PreviewResponse {
    let job = try job(id: jobID)
    guard job.status == "done", let output = job.output, output.lowercased().hasSuffix(".pdf")
    else {
      return PreviewResponse(pages: [])
    }
    let directory = try jobDirectory(jobID)
    let previewDirectory = directory.appendingPathComponent("Preview", isDirectory: true)
    let outputURL = directory.appendingPathComponent(output)
    let urls = try await PreviewCache.pages(pdfURL: outputURL, directory: previewDirectory)
    return PreviewResponse(
      pages: urls.enumerated().map { index, url in
        PreviewPage(page: index + 1, url: url.absoluteString)
      })
  }

  private func launch(jobID: String, metadata: NativeJobMetadata, directory: URL) {
    guard tasks[jobID] == nil else { return }
    var apiKey: String?
    var credentialError: String?
    if metadata.route.kind == "pdf_translate",
      let credential = ProviderCredential(rawValue: metadata.options.provider)
    {
      do {
        apiKey = try credentialStore.value(for: credential)
      } catch {
        credentialError = "无法从 macOS 钥匙串读取翻译 API Key：\(error.localizedDescription)"
      }
    }
    let inputURLs = metadata.inputNames.map { directory.appendingPathComponent("Input/\($0)") }
    let outputURL = directory.appendingPathComponent(
      OutputFileNamer.name(
        for: metadata.route, options: metadata.options, inputNames: metadata.inputNames))

    tasks[jobID] = Task.detached(priority: .userInitiated) { [weak self] in
      guard await self?.markRunning(jobID: jobID, directory: directory) == true else { return }
      do {
        if let credentialError { throw NativeDocumentError.provider(credentialError) }
        let result = try await NativeDocumentProcessor.process(
          route: metadata.route, inputs: inputURLs, options: metadata.options,
          outputURL: outputURL, apiKey: apiKey)
        try Task.checkCancellation()
        await self?.markCompleted(
          jobID: jobID, output: result.outputURL.lastPathComponent, logs: result.logs,
          directory: directory)
      } catch is CancellationError {
        await self?.markCancelled(jobID: jobID, directory: directory)
      } catch {
        await self?.markFailed(jobID: jobID, error: error, directory: directory)
      }
    }
  }

  private func markRunning(jobID: String, directory: URL) -> Bool {
    guard let job = jobs[jobID], job.status != "cancelled" else { return false }
    let updated = replacing(
      job, status: "running", stage: "processing", message: "原生引擎正在处理。", progress: 12,
      logs: job.logs + ["开始使用 macOS 原生框架处理。"])
    do {
      try jobPersister(updated, directory)
      jobs[jobID] = updated
      return true
    } catch {
      jobs[jobID] = persistenceFailure(from: job, action: "无法保存任务启动状态", error: error)
      tasks[jobID] = nil
      appendPersistenceWarning(jobID: jobID, action: "保存任务启动状态", error: error)
      return false
    }
  }

  private func markCompleted(jobID: String, output: String, logs: [String], directory: URL) {
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let updated = replacing(
      job, status: "done", stage: "complete", message: "任务完成。", output: output,
      progress: 100, logs: job.logs + logs)
    tasks[jobID] = nil
    do {
      try jobPersister(updated, directory)
      jobs[jobID] = updated
    } catch {
      jobs[jobID] = appendingLog(
        "警告：结果已生成，但任务完成状态未能保存：\(error.localizedDescription)", to: updated)
      appendPersistenceWarning(jobID: jobID, action: "保存任务完成状态", error: error)
    }
  }

  private func markCancelled(jobID: String, directory: URL) {
    guard !isTerminating else { return }
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let updated = replacing(
      job, status: "cancelled", stage: "cancelled", message: "任务已取消。", progress: job.progress,
      cancelRequested: true, logs: job.logs + ["任务已安全停止。"])
    tasks[jobID] = nil
    do {
      try jobPersister(updated, directory)
      jobs[jobID] = updated
    } catch {
      jobs[jobID] = persistenceFailure(
        from: updated, action: "任务已停止，但无法保存取消状态", error: error,
        cancelRequested: true)
      appendPersistenceWarning(jobID: jobID, action: "保存取消状态", error: error)
    }
  }

  private func markFailed(jobID: String, error: Error, directory: URL) {
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let nativeError = error as? NativeDocumentError
    let updated = replacing(
      job, status: "failed", stage: "failed", message: "任务失败。", error: error.localizedDescription,
      errorCode: nativeError?.code ?? "native_processing_failed",
      errorHint: nativeError?.recoverySuggestion ?? "检查输入文件和参数后重试。",
      retryable: true, progress: job.progress, logs: job.logs)
    tasks[jobID] = nil
    do {
      try jobPersister(updated, directory)
      jobs[jobID] = updated
    } catch {
      let processingError = updated.error ?? "未知处理错误"
      jobs[jobID] = persistenceFailure(
        from: updated, action: "任务失败：\(processingError)。同时无法保存失败状态", error: error)
      appendPersistenceWarning(jobID: jobID, action: "保存任务失败状态", error: error)
    }
  }

  private func recoveredState(
    _ job: JobResponse, metadata: NativeJobMetadata, directory: URL
  ) -> JobResponse? {
    let output = OutputFileNamer.name(
      for: metadata.route, options: metadata.options, inputNames: metadata.inputNames)
    let outputURL = directory.appendingPathComponent(output)
    if Self.isCompleteResult(outputURL) {
      appendLog("已从完整结果恢复任务 \(job.id.prefix(8))，未重新执行处理。")
      return replacing(
        job, status: "done", stage: "complete", message: "任务完成。", output: output,
        progress: 100, logs: job.logs + ["应用重启后从完整结果恢复完成状态。"])
    }

    guard metadata.route.kind == "pdf_translate" else { return nil }

    appendLog("任务 \(job.id.prefix(8)) 上次运行被中断，未自动重新执行。")
    return replacing(
      job, status: "failed", stage: "failed", message: "上次任务被中断。",
      error: "应用退出前未能确认任务完成。为避免重复处理或重复调用翻译服务，任务没有自动重试。",
      errorCode: "task_interrupted",
      errorHint: "确认输入和设置后重新运行。", retryable: true, progress: job.progress,
      logs: job.logs + ["检测到未完成状态，已停止自动恢复。"])
  }

  private func persistenceFailure(
    from job: JobResponse, action: String, error: Error, cancelRequested: Bool = false
  ) -> JobResponse {
    replacing(
      job, status: "failed", stage: "failed", message: "任务状态保存失败。",
      error: "\(action)：\(error.localizedDescription)", errorCode: "job_state_persistence_failed",
      errorHint: "请检查磁盘可用空间和应用数据目录权限后重试。", retryable: true,
      progress: job.progress, cancelRequested: cancelRequested,
      logs: job.logs + ["任务状态未能写入磁盘。"])
  }

  private func appendPersistenceWarning(jobID: String, action: String, error: Error) {
    appendLog("任务 \(jobID.prefix(8)) \(action)失败：\(error.localizedDescription)")
  }

  private func appendingLog(_ text: String, to job: JobResponse) -> JobResponse {
    JobResponse(
      id: job.id, kind: job.kind, status: job.status, inputs: job.inputs,
      createdAt: job.createdAt, updatedAt: job.updatedAt, output: job.output, error: job.error,
      stage: job.stage, message: job.message, errorCode: job.errorCode, errorHint: job.errorHint,
      retryable: job.retryable, progress: job.progress, cancelRequested: job.cancelRequested,
      logs: job.logs + [text])
  }

  private func replacing(
    _ job: JobResponse, status: String, stage: String, message: String,
    output: String? = nil, error: String? = nil, errorCode: String? = nil,
    errorHint: String? = nil, retryable: Bool = false, progress: Int,
    cancelRequested: Bool = false, logs: [String]
  ) -> JobResponse {
    JobResponse(
      id: job.id, kind: job.kind, status: status, inputs: job.inputs,
      createdAt: job.createdAt, updatedAt: ISO8601DateFormatter().string(from: Date()),
      output: output ?? job.output, error: error, stage: stage, message: message,
      errorCode: errorCode, errorHint: errorHint, retryable: retryable, progress: progress,
      cancelRequested: cancelRequested, logs: logs)
  }

  private func credentialStatus(logErrors: Bool) -> [ProviderCredential: Bool] {
    var status: [ProviderCredential: Bool] = [:]
    for credential in ProviderCredential.allCases {
      do {
        let value = try credentialStore.value(for: credential)
        status[credential] = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      } catch {
        status[credential] = false
        if logErrors {
          appendLog("无法读取 \(credential.displayName) API Key：\(error.localizedDescription)")
        }
      }
    }
    return status
  }

  private nonisolated static func copyInputs(
    _ files: [SelectedDocument], to inputDirectory: URL
  ) async throws -> [URL] {
    let transfer = Task.detached(priority: .userInitiated) {
      var copiedInputs: [URL] = []
      for (index, document) in files.enumerated() {
        try Task.checkCancellation()
        let safeName =
          "\(index + 1)-\(document.name.replacingOccurrences(of: "/", with: "-"))"
        let destination = inputDirectory.appendingPathComponent(safeName)
        let accessing = document.url.startAccessingSecurityScopedResource()
        defer { if accessing { document.url.stopAccessingSecurityScopedResource() } }
        do {
          try FileManager.default.copyItem(at: document.url, to: destination)
        } catch {
          throw NativeDocumentError.invalidFile(
            "无法读取 \(document.name)：\(error.localizedDescription)")
        }
        copiedInputs.append(destination)
      }
      return copiedInputs
    }
    return try await withTaskCancellationHandler(
      operation: { try await transfer.value },
      onCancel: { transfer.cancel() })
  }

  private func allowedExtensions(for source: String) -> Set<String> {
    switch source {
    case "pdf": ["pdf"]
    case "image": ["png", "jpg", "jpeg", "tif", "tiff", "heic"]
    case "md": ["md", "txt"]
    case "html": ["html", "htm"]
    case "data": ["txt", "csv", "json"]
    default: []
    }
  }

  private func issue(
    _ code: String, _ message: String, hint: String? = nil
  ) -> PreflightIssue {
    PreflightIssue(code: code, dependency: nil, message: message, hint: hint)
  }

  private nonisolated static func prepareDataDirectory(override: URL?) throws -> (
    directory: URL, warnings: [String]
  ) {
    let directory: URL
    if let override {
      directory = override
    } else {
      let base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      directory = base.appendingPathComponent("Transall", isDirectory: true)
    }
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Jobs", isDirectory: true),
      withIntermediateDirectories: true)
    let jobsDirectory = directory.appendingPathComponent("Jobs", isDirectory: true)
    let directories = try FileManager.default.contentsOfDirectory(
      at: jobsDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles])
    var warnings: [String] = []
    for directory in directories {
      try Task.checkCancellation()
      do {
        let values = try directory.resourceValues(
          forKeys: [.contentModificationDateKey, .isDirectoryKey])
        guard values.isDirectory == true, let modified = values.contentModificationDate,
          Date().timeIntervalSince(modified) > 24 * 60 * 60
        else { continue }
        try FileManager.default.removeItem(at: directory)
      } catch {
        warnings.append("未能清理过期任务 \(directory.lastPathComponent)：\(error.localizedDescription)")
      }
    }
    return (directory, warnings)
  }

  private func jobDirectory(_ id: String) throws -> URL {
    guard let dataDirectory else {
      throw NativeDocumentError.processing("原生文档引擎尚未就绪。")
    }
    let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    guard safe == id else { throw NativeDocumentError.invalidOption("任务编号无效。") }
    let directory = dataDirectory.appendingPathComponent("Jobs/\(safe)", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      throw NativeDocumentError.processing("找不到任务数据。")
    }
    return directory
  }

  private func persistMetadata(_ metadata: NativeJobMetadata, in directory: URL) throws {
    let data = try JSONEncoder().encode(metadata)
    try data.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
  }

  private nonisolated static func persistJob(_ job: JobResponse, in directory: URL) throws {
    let data = try JSONEncoder().encode(job)
    try data.write(to: directory.appendingPathComponent("job.json"), options: .atomic)
  }

  private nonisolated static func isCompleteResult(_ url: URL) -> Bool {
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
      return false
    }
    if url.pathExtension.lowercased() == "pdf" {
      return ((try? NativeDocumentProcessor.previewPageCount(pdfURL: url, limit: 1)) ?? 0) > 0
    }
    return true
  }

  private func load<T: Decodable>(_ name: String, from directory: URL) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
  }

  private func appendLog(_ text: String) {
    guard !text.isEmpty else { return }
    serviceLog.append(text)
    if serviceLog.count > 80 { serviceLog.removeFirst(serviceLog.count - 80) }
  }
}

enum AtomicResultSaver {
  static func copyReplacing(source: URL, destination: URL) throws {
    let manager = FileManager.default
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".transall-save-\(UUID().uuidString)", isDirectory: false)
    do {
      try Task.checkCancellation()
      try manager.copyItem(at: source, to: temporary)
      try Task.checkCancellation()
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: destination)
      }
    } catch {
      try? manager.removeItem(at: temporary)
      throw error
    }
  }
}

enum OutputFileNamer {
  static func name(
    for route: RouteDefinition, options: JobOptions, inputNames: [String]
  ) -> String {
    let firstName = inputNames.first.map(originalInputName) ?? "document"
    let stem = safeOutputStem(
      URL(fileURLWithPath: firstName).deletingPathExtension().lastPathComponent)
    return switch route.kind {
    case "pdf_edit" where options.editAction == "merge": "merged.pdf"
    case "pdf_edit": "\(stem)-edited.pdf"
    case "ocr" where options.ocrOutputFormat == "text": "\(stem)-ocr.txt"
    case "ocr": "\(stem)-ocr.pdf"
    case "extract_markdown": "\(stem).md"
    case "pdf_translate": "\(stem)-translated.pdf"
    case "image_to_pdf" where inputNames.count > 1: "images.pdf"
    default: "\(stem).pdf"
    }
  }

  private static func originalInputName(_ value: String) -> String {
    value.replacingOccurrences(
      of: #"^\d+-"#, with: "", options: .regularExpression)
  }

  private static func safeOutputStem(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
    let filtered = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
    let result = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
    return String((result.isEmpty ? "document" : result).prefix(80))
  }
}

enum PreviewCache {
  static func pages(pdfURL: URL, directory: URL, limit: Int = 8) async throws -> [URL] {
    let generation = Task.detached(priority: .userInitiated) {
      try cachedPages(pdfURL: pdfURL, directory: directory, limit: limit)
    }
    return try await withTaskCancellationHandler(
      operation: { try await generation.value },
      onCancel: { generation.cancel() })
  }

  private static func cachedPages(pdfURL: URL, directory: URL, limit: Int) throws -> [URL] {
    try Task.checkCancellation()
    let expectedCount = try NativeDocumentProcessor.previewPageCount(
      pdfURL: pdfURL, limit: limit)
    guard expectedCount > 0 else {
      try? FileManager.default.removeItem(at: directory)
      return []
    }

    let existing = previewFiles(in: directory)
    if isComplete(existing, expectedCount: expectedCount) {
      return existing
    }

    try? FileManager.default.removeItem(at: directory)
    do {
      let generated = try NativeDocumentProcessor.makePreviews(
        pdfURL: pdfURL, directory: directory, limit: limit)
      guard isComplete(generated, expectedCount: expectedCount) else {
        throw NativeDocumentError.processing("PDF 预览生成不完整，请重试。")
      }
      return generated
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  private static func previewFiles(in directory: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension.lowercased() == "png" }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
  }

  private static func isComplete(_ urls: [URL], expectedCount: Int) -> Bool {
    guard urls.count == expectedCount else { return false }
    return urls.enumerated().allSatisfy { index, url in
      url.lastPathComponent == "page-\(index + 1).png"
        && NativeDocumentProcessor.isReadableImage(url)
    }
  }
}

private struct NativeJobMetadata: Codable {
  let route: RouteDefinition
  let options: JobOptions
  let inputNames: [String]
}
