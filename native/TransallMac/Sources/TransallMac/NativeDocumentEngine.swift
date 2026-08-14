import Combine
import Foundation

@MainActor
final class NativeDocumentEngine: ObservableObject {
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
  private var dataDirectory: URL?
  private var isTerminating = false

  func start() async {
    state = .starting
    do {
      dataDirectory = try applicationDataDirectory()
      try removeExpiredJobs()
      state = .running
      appendLog("PDFKit、Core Graphics 和 Vision 已就绪。")
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
    NativeCapabilities.diagnostics(providerConfigured: credentialStatus())
  }

  func providers() -> ProvidersResponse {
    NativeCapabilities.providers(configured: credentialStatus())
  }

  func applyCredentialChanges() async -> String {
    "密钥已保存到钥匙串。"
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
    for file in files where !allowed.contains(file.url.pathExtension.lowercased()) {
      blocking.append(
        issue(
          "invalid_file_type", "\(file.name) 不符合此路径的输入格式。",
          hint: "请选择：\(allowed.sorted().joined(separator: ", "))"))
    }
    if route.kind == "pdf_edit", options.editAction == "merge", files.count < 2 {
      blocking.append(issue("merge_requires_files", "合并 PDF 至少需要两个文件。"))
    }
    if route.kind == "pdf_translate" {
      let credential: ProviderCredential = options.provider == "openai" ? .openAI : .deepseek
      let key = (try? ProviderCredentialStore.shared.value(for: credential)) ?? ""
      if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocking.append(
          issue(
            "provider_not_configured",
            "\(options.provider == "openai" ? "OpenAI" : "DeepSeek") API Key 尚未配置。",
            hint: "打开 Transall 设置并保存 API Key。"))
      }
      warnings.append(
        issue(
          "remote_processing", "翻译时，提取出的文档文字会发送给所选服务商。",
          hint: "PDF 原文件不会上传。"))
    }
    if route.kind == "pdf_edit", !options.replaceFind.isEmpty || !options.replaceWith.isEmpty {
      blocking.append(
        issue(
          "unsupported_text_replacement", "原生 PDF 编辑不支持可靠替换现有文字。",
          hint: "请清空查找和替换字段；首版支持页面整理、裁剪和水印。"))
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
    try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
    var copiedInputs: [URL] = []
    for (index, document) in files.enumerated() {
      let safeName = "\(index + 1)-\(document.name.replacingOccurrences(of: "/", with: "-"))"
      let destination = inputDirectory.appendingPathComponent(safeName)
      let accessing = document.url.startAccessingSecurityScopedResource()
      defer { if accessing { document.url.stopAccessingSecurityScopedResource() } }
      do {
        try FileManager.default.copyItem(at: document.url, to: destination)
      } catch {
        throw NativeDocumentError.invalidFile("无法读取 \(document.name)：\(error.localizedDescription)")
      }
      copiedInputs.append(destination)
    }

    let now = ISO8601DateFormatter().string(from: Date())
    let job = JobResponse(
      id: id, kind: route.kind, status: "queued", inputs: files.map(\.name), createdAt: now,
      updatedAt: now, output: nil, error: nil, stage: "queued", message: "任务已进入队列。",
      errorCode: nil, errorHint: nil, retryable: false, progress: 0,
      cancelRequested: false, logs: ["已将输入副本保存到应用沙盒。"])
    let metadata = NativeJobMetadata(
      route: route, options: options, inputNames: copiedInputs.map(\.lastPathComponent))
    jobs[id] = job
    try persist(job, in: directory)
    try persist(metadata, in: directory)
    launch(jobID: id, metadata: metadata, directory: directory)
    return job
  }

  func job(id: String) throws -> JobResponse {
    if let job = jobs[id] { return job }
    let directory = try jobDirectory(id)
    let job: JobResponse = try load("job.json", from: directory)
    jobs[id] = job
    if job.isRunning, tasks[id] == nil {
      let metadata: NativeJobMetadata = try load("metadata.json", from: directory)
      appendLog("正在恢复上次未完成的任务 \(id.prefix(8))。")
      launch(jobID: id, metadata: metadata, directory: directory)
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
    jobs[id] = job
    tasks[id]?.cancel()
    tasks[id] = nil
    try persist(job, in: try jobDirectory(id))
    return job
  }

  func deleteJob(id: String) throws {
    guard let job = try? job(id: id), !job.isRunning else {
      throw NativeDocumentError.processing("正在运行的任务不能删除。")
    }
    tasks[id]?.cancel()
    tasks[id] = nil
    jobs[id] = nil
    let directory = try jobDirectory(id)
    if FileManager.default.fileExists(atPath: directory.path) {
      try FileManager.default.removeItem(at: directory)
    }
  }

  func download(jobID: String, to destination: URL) throws {
    let job = try job(id: jobID)
    guard job.status == "done", let output = job.output else {
      throw NativeDocumentError.processing("任务还没有可保存的结果。")
    }
    let source = try jobDirectory(jobID).appendingPathComponent(output)
    let accessing = destination.startAccessingSecurityScopedResource()
    defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.copyItem(at: source, to: destination)
  }

  func previewPages(jobID: String) async throws -> PreviewResponse {
    let job = try job(id: jobID)
    guard job.status == "done", let output = job.output, output.lowercased().hasSuffix(".pdf")
    else {
      return PreviewResponse(pages: [])
    }
    let directory = try jobDirectory(jobID)
    let previewDirectory = directory.appendingPathComponent("Preview", isDirectory: true)
    let existing =
      (try? FileManager.default.contentsOfDirectory(
        at: previewDirectory, includingPropertiesForKeys: nil))?.filter {
        $0.pathExtension == "png"
      }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      } ?? []
    let urls: [URL]
    if existing.isEmpty {
      let outputURL = directory.appendingPathComponent(output)
      urls = try await Task.detached {
        try NativeDocumentProcessor.makePreviews(pdfURL: outputURL, directory: previewDirectory)
      }.value
    } else {
      urls = existing
    }
    return PreviewResponse(
      pages: urls.enumerated().map { index, url in
        PreviewPage(page: index + 1, url: url.absoluteString)
      })
  }

  private func launch(jobID: String, metadata: NativeJobMetadata, directory: URL) {
    guard tasks[jobID] == nil else { return }
    let credential: ProviderCredential = metadata.options.provider == "openai" ? .openAI : .deepseek
    let apiKey = try? ProviderCredentialStore.shared.value(for: credential)
    let inputURLs = metadata.inputNames.map { directory.appendingPathComponent("Input/\($0)") }
    let outputURL = directory.appendingPathComponent(
      OutputFileNamer.name(
        for: metadata.route, options: metadata.options, inputNames: metadata.inputNames))

    tasks[jobID] = Task.detached(priority: .userInitiated) { [weak self] in
      await self?.markRunning(jobID: jobID, directory: directory)
      do {
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

  private func markRunning(jobID: String, directory: URL) {
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let updated = replacing(
      job, status: "running", stage: "processing", message: "原生引擎正在处理。", progress: 12,
      logs: job.logs + ["开始使用 macOS 原生框架处理。"])
    jobs[jobID] = updated
    try? persist(updated, in: directory)
  }

  private func markCompleted(jobID: String, output: String, logs: [String], directory: URL) {
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let updated = replacing(
      job, status: "done", stage: "complete", message: "任务完成。", output: output,
      progress: 100, logs: job.logs + logs)
    jobs[jobID] = updated
    tasks[jobID] = nil
    try? persist(updated, in: directory)
  }

  private func markCancelled(jobID: String, directory: URL) {
    guard !isTerminating else { return }
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let updated = replacing(
      job, status: "cancelled", stage: "cancelled", message: "任务已取消。", progress: job.progress,
      cancelRequested: true, logs: job.logs + ["任务已安全停止。"])
    jobs[jobID] = updated
    tasks[jobID] = nil
    try? persist(updated, in: directory)
  }

  private func markFailed(jobID: String, error: Error, directory: URL) {
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let updated = replacing(
      job, status: "failed", stage: "failed", message: "任务失败。", error: error.localizedDescription,
      errorCode: "native_processing_failed", errorHint: "检查输入文件和参数后重试。",
      retryable: true, progress: job.progress, logs: job.logs)
    jobs[jobID] = updated
    tasks[jobID] = nil
    try? persist(updated, in: directory)
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

  private func credentialStatus() -> [ProviderCredential: Bool] {
    Dictionary(
      uniqueKeysWithValues: ProviderCredential.allCases.map { credential in
        let value = (try? ProviderCredentialStore.shared.value(for: credential)) ?? ""
        return (credential, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      })
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

  private func applicationDataDirectory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = base.appendingPathComponent("Transall", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Jobs", isDirectory: true),
      withIntermediateDirectories: true)
    return directory
  }

  private func removeExpiredJobs(now: Date = Date()) throws {
    guard let dataDirectory else { return }
    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    let directories = try FileManager.default.contentsOfDirectory(
      at: jobsDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      options: [.skipsHiddenFiles])
    for directory in directories {
      let values = try directory.resourceValues(
        forKeys: [.contentModificationDateKey, .isDirectoryKey])
      guard values.isDirectory == true, let modified = values.contentModificationDate,
        now.timeIntervalSince(modified) > 24 * 60 * 60
      else { continue }
      try FileManager.default.removeItem(at: directory)
    }
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

  private func persist<T: Encodable>(_ value: T, in directory: URL) throws {
    let name = value is NativeJobMetadata ? "metadata.json" : "job.json"
    let data = try JSONEncoder().encode(value)
    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
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

private struct NativeJobMetadata: Codable {
  let route: RouteDefinition
  let options: JobOptions
  let inputNames: [String]
}
