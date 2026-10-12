import Combine
import Foundation

@MainActor
final class NativeDocumentEngine: ObservableObject {
  typealias JobPersister = (JobResponse, URL) throws -> Void
  typealias JobProcessor =
    @Sendable (
      RouteDefinition, [URL], JobOptions, URL, String?
    ) async throws -> NativeDocumentProcessor.Result
  typealias InputCopier =
    @Sendable (
      _ files: [SelectedDocument], _ inputDirectory: URL, _ maximumBytes: Int, _ maximumMB: Int
    ) async throws -> [URL]
  typealias PreviewGenerator = @Sendable (URL, URL) async throws -> [URL]

  private struct PreviewOperation {
    let token: UUID
    let task: Task<[URL], Error>
  }

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
  @Published private(set) var taskProgress: [String: [TaskProgressLine]] = [:]

  private var jobs: [String: JobResponse] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  private var previewOperations: [String: PreviewOperation] = [:]
  private var deletingJobs: Set<String> = []
  private var dataDirectory: URL?
  private let dataDirectoryOverride: URL?
  private let jobPersister: JobPersister
  private let jobProcessor: JobProcessor
  private let inputCopier: InputCopier
  private let credentialWorker: ProviderCredentialWorker
  private let previewGenerator: PreviewGenerator
  private var isTerminating = false

  init(
    dataDirectoryOverride: URL? = nil, jobPersister: JobPersister? = nil,
    credentialStore: (any ProviderCredentialStoring)? = nil,
    credentialWorker: ProviderCredentialWorker? = nil,
    jobProcessor: JobProcessor? = nil,
    inputCopier: InputCopier? = nil,
    previewGenerator: PreviewGenerator? = nil
  ) {
    self.dataDirectoryOverride = dataDirectoryOverride
    if let credentialWorker {
      self.credentialWorker = credentialWorker
    } else if let credentialStore {
      self.credentialWorker = ProviderCredentialWorker(store: credentialStore)
    } else {
      self.credentialWorker = .shared
    }
    self.jobProcessor =
      jobProcessor ?? { route, inputs, options, outputURL, apiKey in
        try await NativeDocumentProcessor.process(
          route: route, inputs: inputs, options: options, outputURL: outputURL, apiKey: apiKey)
      }
    self.inputCopier =
      inputCopier ?? { files, inputDirectory, maximumBytes, maximumMB in
        try await JobStorage.copyInputs(
          files, to: inputDirectory, maximumBytes: maximumBytes, maximumMB: maximumMB)
      }
    self.previewGenerator =
      previewGenerator ?? { pdfURL, directory in
        try await PreviewCache.pages(pdfURL: pdfURL, directory: directory)
      }
    self.jobPersister =
      jobPersister ?? { job, directory in
        try JobStorage.persistJob(job, in: directory)
      }
  }

  func start() async {
    state = .starting
    do {
      let override = dataDirectoryOverride
      let preparation = Task.detached(priority: .utility) {
        try JobStorage.prepareDataDirectory(override: override)
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
    for operation in previewOperations.values { operation.task.cancel() }
    previewOperations.removeAll()
  }

  func capabilities() -> CapabilitiesResponse { NativeCapabilities.response }

  func environment() async -> NativeEnvironmentSnapshot {
    let status = await credentialWorker.status()
    for credential in ProviderCredential.allCases {
      if let error = status.errors[credential] {
        appendLog("无法使用 \(credential.displayName) API Key：\(error)")
      }
    }
    return NativeEnvironmentSnapshot(
      diagnostics: NativeCapabilities.diagnostics(providerConfigured: status.configured),
      providers: NativeCapabilities.providers(
        configured: status.configured, requiresAuthorization: status.requiresAuthorization))
  }

  func applyCredentialChanges() async -> String {
    "翻译服务配置已更新。"
  }

  func preflight(
    route: RouteDefinition, files: [SelectedDocument], options: JobOptions
  ) async -> PreflightResponse {
    var response = makePreflight(route: route, files: files, options: options)
    guard route.kind == "pdf_translate",
      let credential = ProviderCredential(rawValue: options.provider)
    else { return response }

    var blocking = response.blockingIssues
    do {
      let key = try await credentialWorker.value(for: credential)
      do {
        _ = try ProviderCredentialPolicy.normalizedValue(key, allowingEmpty: false)
      } catch let error as ProviderCredentialValidationError {
        let isMissing = error == .missing
        blocking.append(
          issue(
            isMissing ? "provider_not_configured" : "provider_key_invalid",
            isMissing
              ? "\(credential.displayName) API Key 尚未配置。"
              : "\(credential.displayName) API Key 格式无效。",
            hint: isMissing ? "打开 Transall 设置并保存 API Key。" : error.localizedDescription))
      }
    } catch {
      blocking.append(
        issue(
          "provider_keychain_unavailable", "无法从 本机配置文件读取翻译 API Key。",
          hint: error.localizedDescription))
    }
    response = PreflightResponse(
      ok: blocking.isEmpty, blockingIssues: blocking, warnings: response.warnings,
      requirements: response.requirements)
    return response
  }

  private func makePreflight(
    route: RouteDefinition, files: [SelectedDocument], options: JobOptions
  ) -> PreflightResponse {
    var blocking: [PreflightIssue] = []
    var warnings: [PreflightIssue] = []
    guard JobStorage.canonicalRoute(matching: route) != nil else {
      blocking.append(
        issue(
          "unsupported_route", "此转换路径不属于当前原生版本。",
          hint: "请重新选择源格式和目标格式。"))
      return PreflightResponse(
        ok: false, blockingIssues: blocking, warnings: [], requirements: [])
    }
    if route.kind == "office_convert", OfficeConversionComponent.requiresSetup {
      blocking.append(issue("office_component_setup", OfficeConversionComponent.setupMessage))
    }
    if route.kind == "office_convert", OfficeDocumentConverter.executable == nil {
      blocking.append(issue("missing_office_converter", OfficeDocumentConverter.missingMessage))
    }
    if files.count > NativeCapabilities.maximumInputFileCount {
      blocking.append(
        issue(
          "too_many_files",
          "每批最多处理 \(NativeCapabilities.maximumInputFileCount) 个文件。",
          hint: "请拆分为多个任务。"))
      return PreflightResponse(
        ok: false, blockingIssues: blocking, warnings: [], requirements: route.requirements)
    }
    var total = Int64.zero
    var totalOverflowed = false
    for file in files where file.size > 0 {
      let addition = total.addingReportingOverflow(file.size)
      total = addition.overflow ? Int64.max : addition.partialValue
      totalOverflowed = totalOverflowed || addition.overflow
    }
    let inputLimitBytes = NativeCapabilities.inputLimitBytes(for: route)
    let inputLimitMB = NativeCapabilities.inputLimitMB(for: route)
    if files.isEmpty {
      blocking.append(issue("missing_files", "请选择至少一个文件。"))
    } else if totalOverflowed || total > Int64(inputLimitBytes) {
      blocking.append(issue("upload_too_large", "所选文件总计超过 \(inputLimitMB) MB。"))
    }

    let allowed = allowedExtensions(for: route.source)
    for file in files where file.size <= 0 {
      blocking.append(
        issue("empty_file", "\(file.name) 的文件大小无效。", hint: "请选择包含内容的文件。"))
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
    blocking.append(
      contentsOf: JobOptionValidator.issues(for: route, options: options).map {
        issue($0.code, $0.message, hint: $0.hint)
      })
    if route.kind == "pdf_translate" {
      if files.count != 1 {
        blocking.append(
          issue(
            "single_file_required", "PDF 翻译每次只能处理一个文件。",
            hint: "请移除多余文件后再开始翻译。"))
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
    let validation = makePreflight(route: route, files: files, options: options)
    if let issue = validation.blockingIssues.first {
      throw Self.preflightError(issue)
    }
    guard let canonicalRoute = JobStorage.canonicalRoute(matching: route) else {
      throw NativeDocumentError.invalidOption("此转换路径不属于当前原生版本。")
    }
    let id = UUID().uuidString.lowercased()
    let directory = dataDirectory.appendingPathComponent("Jobs/\(id)", isDirectory: true)
    let inputDirectory = directory.appendingPathComponent("Input", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
      let copiedInputs = try await inputCopier(
        files, inputDirectory, NativeCapabilities.inputLimitBytes(for: canonicalRoute),
        NativeCapabilities.inputLimitMB(for: canonicalRoute))

      let now = ISO8601DateFormatter().string(from: Date())
      let job = JobResponse(
        id: id, kind: canonicalRoute.kind, status: "queued", inputs: files.map(\.name),
        createdAt: now,
        updatedAt: now, output: nil, error: nil, stage: "queued", message: "任务已进入队列。",
        errorCode: nil, errorHint: nil, retryable: false, progress: 0,
        cancelRequested: false, logs: ["已将输入副本保存到应用沙盒。"])
      let metadata = NativeJobMetadata(
        route: canonicalRoute, options: options.canonicalized(for: canonicalRoute),
        inputNames: copiedInputs.map(\.lastPathComponent))
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
    guard job.id == id else {
      throw NativeDocumentError.invalidFile("任务状态与任务编号不一致，数据可能已经损坏。")
    }
    if job.isRunning, tasks[id] == nil {
      let metadata: NativeJobMetadata
      do {
        metadata = try load("metadata.json", from: directory)
        try JobStorage.validateStoredMetadata(metadata, for: job)
      } catch {
        let corrupted = replacing(
          job, status: "failed", stage: "failed", message: "任务数据已损坏。",
          error: error.localizedDescription, errorCode: "job_state_corrupt",
          errorHint: "删除这项本地任务后，重新选择原文件运行。", retryable: false,
          progress: job.progress, logs: job.logs + ["任务恢复已停止：本地状态校验失败。"])
        jobs[id] = corrupted
        do {
          try jobPersister(corrupted, directory)
        } catch {
          jobs[id] = appendingLog(
            "警告：损坏状态未能保存：\(error.localizedDescription)", to: corrupted)
          appendPersistenceWarning(jobID: id, action: "保存损坏状态", error: error)
        }
        return jobs[id] ?? corrupted
      }
      jobs[id] = job
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
    } else {
      jobs[id] = job
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

  func discardJob(id: String) async throws {
    let job = try job(id: id)
    if job.isRunning {
      _ = try? cancelJob(id: id)
    }
    try await deleteJob(id: id)
  }

  func deleteJob(id: String) async throws {
    let directory = try jobDirectory(id)
    if jobs[id]?.isRunning == true {
      throw NativeDocumentError.processing("正在运行的任务不能删除。")
    }
    if jobs[id] == nil, let persisted: JobResponse = try? load("job.json", from: directory),
      persisted.id == id, persisted.isRunning,
      let metadata: NativeJobMetadata = try? load("metadata.json", from: directory),
      (try? JobStorage.validateStoredMetadata(metadata, for: persisted)) != nil
    {
      throw NativeDocumentError.processing("正在运行的任务不能删除。")
    }
    guard deletingJobs.insert(id).inserted else {
      throw NativeDocumentError.processing("任务数据正在删除。")
    }
    defer { deletingJobs.remove(id) }

    if let task = tasks[id] {
      task.cancel()
      await task.value
      tasks[id] = nil
    }

    if let operation = previewOperations[id] {
      operation.task.cancel()
      _ = try? await operation.task.value
      if previewOperations[id]?.token == operation.token {
        previewOperations[id] = nil
      }
    }

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

  func cleanupExpiredJobs(now: Date = Date()) async -> Set<String> {
    guard state == .running, let dataDirectory else { return [] }
    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    let scanTask = Task.detached(priority: .utility) {
      try JobStorage.expiredJobDirectories(in: jobsDirectory, now: now)
    }
    let scan: JobStorage.CleanupScan
    do {
      scan = try await withTaskCancellationHandler(
        operation: { try await scanTask.value },
        onCancel: { scanTask.cancel() })
    } catch is CancellationError {
      return []
    } catch {
      appendLog("无法检查过期任务：\(error.localizedDescription)")
      return []
    }
    scan.warnings.forEach(appendLog)

    var removed: Set<String> = []
    for directory in scan.directories {
      guard !Task.isCancelled else { return removed }
      let id = directory.lastPathComponent
      guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
        appendLog("过期任务目录编号无效，已留待下次启动清理：\(id)")
        continue
      }
      guard jobs[id]?.isRunning != true else { continue }
      do {
        try await deleteJob(id: id)
        removed.insert(id)
      } catch {
        appendLog("未能清理过期任务 \(id.prefix(8))：\(error.localizedDescription)")
      }
    }
    if !removed.isEmpty {
      appendLog("已自动清理 \(removed.count) 个超过 24 小时的本地任务。")
    }
    return removed
  }

  func download(
    jobID: String, to destination: URL,
    allowReplacingExistingDestination: Bool = true
  ) async throws {
    let job = try job(id: jobID)
    guard job.status == "done", let output = job.output else {
      throw NativeDocumentError.processing("任务还没有可保存的结果。")
    }
    let directory = try jobDirectory(jobID)
    let transfer = Task.detached(priority: .userInitiated) {
      let accessing = destination.startAccessingSecurityScopedResource()
      defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
      let verified = try JobStorage.validatedCompletedResult(named: output, in: directory)
      try AtomicResultSaver.copyReplacing(
        source: verified.url, destination: destination,
        expectedFingerprint: verified.fingerprint,
        allowReplacingExistingDestination: allowReplacingExistingDestination)
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
    guard previewOperations[jobID] == nil else {
      throw NativeDocumentError.processing("这个任务的 PDF 预览正在生成。")
    }
    let token = UUID()
    let previewGenerator = self.previewGenerator
    let operation = Task.detached(priority: .userInitiated) {
      do {
        let verified = try JobStorage.validatedCompletedResult(named: output, in: directory)
        let pages = try await previewGenerator(verified.url, previewDirectory)
        _ = try JobStorage.validatedCompletedResult(named: output, in: directory)
        try Task.checkCancellation()
        return pages
      } catch {
        try? FileManager.default.removeItem(at: previewDirectory)
        throw error
      }
    }
    previewOperations[jobID] = PreviewOperation(token: token, task: operation)
    defer {
      if previewOperations[jobID]?.token == token {
        previewOperations[jobID] = nil
      }
    }
    let urls = try await withTaskCancellationHandler(
      operation: { try await operation.value },
      onCancel: { operation.cancel() })
    return PreviewResponse(
      pages: urls.enumerated().map { index, url in
        PreviewPage(page: index + 1, url: url.absoluteString)
      })
  }

  func taskConfiguration(jobID: String) throws -> (route: RouteDefinition, options: JobOptions) {
    let job = try job(id: jobID)
    let metadata: NativeJobMetadata = try load("metadata.json", from: jobDirectory(jobID))
    try JobStorage.validateStoredMetadata(metadata, for: job)
    return (metadata.route, metadata.options)
  }

  func inspectionSnapshot(jobID: String) async throws -> DocumentInspectionSnapshot {
    let job = try job(id: jobID)
    let hasOutput = job.status == "done" && job.output != nil
    let hasRecovery = job.kind == "pdf_translate" && ["failed", "cancelled"].contains(job.status)
    guard !deletingJobs.contains(jobID), hasOutput || hasRecovery
    else { throw NativeDocumentError.processing("这个任务没有可检查的 PDF 结果。") }
    let directory = try jobDirectory(jobID)
    let metadata: NativeJobMetadata = try load("metadata.json", from: directory)
    try JobStorage.validateStoredMetadata(metadata, for: job)
    let operation = Task.detached(priority: .userInitiated) {
      let snapshotDirectory = directory.appendingPathComponent(
        "Inspection-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: snapshotDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      var completed = false
      defer { if !completed { try? FileManager.default.removeItem(at: snapshotDirectory) } }
      var result: URL?
      if hasOutput, let output = job.output {
        let verified = try JobStorage.validatedCompletedResult(named: output, in: directory)
        let copy = snapshotDirectory.appendingPathComponent(output)
        try AtomicResultSaver.copyReplacing(
          source: verified.url, destination: copy,
          expectedFingerprint: verified.fingerprint, allowReplacingExistingDestination: false)
        result = copy
      }
      var original: URL?
      if metadata.inputNames.count == 1, let input = metadata.inputNames.first,
        input.lowercased().hasSuffix(".pdf")
      {
        let inputDirectory = directory.appendingPathComponent("Input", isDirectory: true)
        try JobStorage.validateDirectory(inputDirectory, description: "任务输入目录")
        let source = try JobStorage.validatedRegularFile(
          named: input, in: inputDirectory, description: "任务输入")
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= NativeCapabilities.uploadLimitBytes else {
          throw NativeDocumentError.invalidFile("任务输入超过检查文件的大小上限。")
        }
        let copy = snapshotDirectory.appendingPathComponent("original.pdf")
        try AtomicResultSaver.copyReplacing(
          source: source, destination: copy, allowReplacingExistingDestination: false)
        original = copy
      }
      let bilingualDownload = result.map { PDFLayoutTranslation.isSideBySideBilingual($0) } ?? false
      var issues: [TranslationLayoutIssue] = []
      if hasRecovery {
        guard let original else {
          throw NativeDocumentError.invalidFile("无法找到这项翻译任务的原文副本。")
        }
        let recovery = try TranslationRecoveryStore.load(
          in: directory, inputURL: original, options: metadata.options)
        issues = recovery.issues
      }
      try Task.checkCancellation()
      completed = true
      return DocumentInspectionSnapshot(
        directory: snapshotDirectory, result: result, original: original, issues: issues,
        bilingualDownload: bilingualDownload)
    }
    return try await withTaskCancellationHandler(
      operation: { try await operation.value }, onCancel: { operation.cancel() })
  }

  func translationRecovery(jobID: String, allowingIncomplete: Bool = false) async throws
    -> TranslationRecoveryDocument
  {
    let job = try job(id: jobID)
    guard job.kind == "pdf_translate", ["failed", "cancelled"].contains(job.status),
      !deletingJobs.contains(jobID)
    else { throw NativeDocumentError.processing("这个任务没有可恢复的译文。") }
    if let task = tasks[jobID] {
      await task.value
      try Task.checkCancellation()
    }
    guard !deletingJobs.contains(jobID), tasks[jobID] == nil,
      ["failed", "cancelled"].contains(try self.job(id: jobID).status)
    else { throw NativeDocumentError.processing("这个任务现在不能读取已保存译文。") }
    let directory = try jobDirectory(jobID)
    let metadata: NativeJobMetadata = try load("metadata.json", from: directory)
    try JobStorage.validateStoredMetadata(metadata, for: job)
    let operation = Task.detached(priority: .userInitiated) {
      let inputs = try JobStorage.validatedStoredInputs(named: metadata.inputNames, in: directory)
      guard inputs.count == 1, let input = inputs.first else {
        throw NativeDocumentError.invalidFile("翻译恢复需要一份原文副本。")
      }
      return try TranslationRecoveryStore.load(
        in: directory, inputURL: input, options: metadata.options,
        allowingIncomplete: allowingIncomplete)
    }
    return try await withTaskCancellationHandler(
      operation: { try await operation.value }, onCancel: { operation.cancel() })
  }

  func recoverTranslationAsPlainPDF(jobID: String) throws -> JobResponse {
    try rebuildTranslationPDF(jobID: jobID, outputMode: "translated")
  }

  func rebuildTranslationPDF(jobID: String, outputMode: String) throws -> JobResponse {
    guard ["translated", "preserve_layout", "bilingual"].contains(outputMode) else {
      throw NativeDocumentError.processing("不支持的译文输出格式。")
    }
    let job = try job(id: jobID)
    guard job.kind == "pdf_translate",
      ["failed", "cancelled"].contains(job.status)
        || (job.status == "done" && outputMode != "translated"),
      !deletingJobs.contains(jobID), tasks[jobID] == nil, !isTerminating
    else { throw NativeDocumentError.processing("这个任务现在不能重新排版。") }
    let directory = try jobDirectory(jobID)
    let metadata: NativeJobMetadata = try load("metadata.json", from: directory)
    try JobStorage.validateStoredMetadata(metadata, for: job)
    var options = metadata.options
    options.outputMode = outputMode
    let revised = NativeJobMetadata(
      route: metadata.route, options: options, inputNames: metadata.inputNames)
    let queued = replacing(
      job, status: "queued", stage: "queued", message: "正在准备已保存的译文。",
      progress: 0, cancelRequested: false,
      logs: job.logs + ["已选择使用本机保存的译文重新生成 PDF；不会再次读取密钥或请求翻译服务。"])
    try persistMetadata(revised, in: directory)
    do {
      try jobPersister(queued, directory)
    } catch {
      try? persistMetadata(metadata, in: directory)
      throw error
    }
    jobs[jobID] = queued
    launchRecoveredTranslation(jobID: jobID, metadata: revised, directory: directory)
    return queued
  }

  private func launchRecoveredTranslation(
    jobID: String, metadata: NativeJobMetadata, directory: URL
  ) {
    // This path deliberately has no credential lookup or translation-service processor call.
    tasks[jobID] = Task.detached(priority: .userInitiated) { [weak self] in
      guard
        await self?.markRunning(
          jobID: jobID, directory: directory,
          message: "正在使用已保存的译文重新排版。") == true
      else { return }
      var outputURL: URL?
      do {
        try Task.checkCancellation()
        let inputs = try JobStorage.validatedStoredInputs(named: metadata.inputNames, in: directory)
        guard inputs.count == 1, let input = inputs.first else {
          throw NativeDocumentError.invalidFile("翻译恢复需要一份原文副本。")
        }
        let recovery = try TranslationRecoveryStore.load(
          in: directory, inputURL: input, options: metadata.options)
        let destination = try JobStorage.containedFileURL(
          named: OutputFileNamer.name(
            for: metadata.route, options: metadata.options, inputNames: metadata.inputNames),
          in: directory, description: "恢复的译文结果")
        let renderingDirectory = directory.appendingPathComponent(
          "Recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
          at: renderingDirectory, withIntermediateDirectories: false,
          attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: renderingDirectory) }
        let rendered = renderingDirectory.appendingPathComponent("translated.pdf")
        let result = try NativeDocumentProcessor.renderRecoveredTranslation(
          recovery, to: rendered,
          layoutInputURL: metadata.options.outputMode == "translated" ? nil : input,
          bilingual: metadata.options.outputMode == "bilingual")
        try Task.checkCancellation()
        guard result.outputURL.standardizedFileURL == rendered.standardizedFileURL,
          JobStorage.isCompleteResult(rendered)
        else {
          throw NativeDocumentError.processing("重新排版没有生成完整可用的 PDF。")
        }
        try AtomicResultSaver.copyReplacing(source: rendered, destination: destination)
        outputURL = destination
        try Task.checkCancellation()
        let accepted =
          await self?.markCompleted(
            jobID: jobID, output: destination.lastPathComponent, logs: result.logs,
            directory: directory) == true
        if !accepted {
          await self?.removeIncompleteOutput(at: destination, jobID: jobID)
          await self?.markCancelled(jobID: jobID, directory: directory)
        }
      } catch is CancellationError {
        if let outputURL { await self?.removeIncompleteOutput(at: outputURL, jobID: jobID) }
        await self?.markCancelled(jobID: jobID, directory: directory)
      } catch {
        if let outputURL { await self?.removeIncompleteOutput(at: outputURL, jobID: jobID) }
        await self?.markFailed(jobID: jobID, error: error, directory: directory)
      }
    }
  }

  private func launch(jobID: String, metadata: NativeJobMetadata, directory: URL) {
    guard tasks[jobID] == nil else { return }
    let jobProcessor = self.jobProcessor
    let credentialWorker = self.credentialWorker
    tasks[jobID] = Task.detached(priority: .userInitiated) { [weak self] in
      guard await self?.markRunning(jobID: jobID, directory: directory) == true else { return }
      var outputURL: URL?
      do {
        var apiKey: String?
        if metadata.route.kind == "pdf_translate",
          let credential = ProviderCredential(rawValue: metadata.options.provider)
        {
          let storedKey: String
          do {
            storedKey = try await credentialWorker.value(for: credential)
          } catch {
            throw NativeDocumentError.provider(
              "无法从 本机配置文件读取翻译 API Key：\(error.localizedDescription)")
          }
          do {
            apiKey = try ProviderCredentialPolicy.normalizedValue(
              storedKey, allowingEmpty: false)
          } catch let error as ProviderCredentialValidationError {
            if error == .missing {
              throw NativeDocumentError.provider("\(credential.displayName) API Key 尚未配置。")
            }
            throw NativeDocumentError.provider(
              "\(credential.displayName) API Key 格式无效：\(error.localizedDescription)")
          }
        }
        try Task.checkCancellation()
        let expectedOutputURL = try JobStorage.containedFileURL(
          named: OutputFileNamer.name(
            for: metadata.route, options: metadata.options, inputNames: metadata.inputNames),
          in: directory, description: "任务结果")
        outputURL = expectedOutputURL
        let inputURLs = try JobStorage.validatedStoredInputs(
          named: metadata.inputNames, in: directory)
        let result = try await ProcessingProgress.$reporter.withValue(
          { [weak self] line in await self?.updateProgress(line, jobID: jobID) }
        ) {
          try await jobProcessor(
            metadata.route, inputURLs, metadata.options, expectedOutputURL, apiKey)
        }
        try Task.checkCancellation()
        await self?.updateProgress(TaskProgressLine(title: "正在检查结果"), jobID: jobID)
        guard result.outputURL.standardizedFileURL == expectedOutputURL.standardizedFileURL else {
          throw NativeDocumentError.processing("处理器返回了意外的结果位置。")
        }
        guard JobStorage.isCompleteResult(expectedOutputURL) else {
          throw NativeDocumentError.processing("处理器没有生成完整可用的结果。")
        }
        let accepted =
          await self?.markCompleted(
            jobID: jobID, output: expectedOutputURL.lastPathComponent, logs: result.logs,
            directory: directory) == true
        if !accepted {
          await self?.removeIncompleteOutput(at: expectedOutputURL, jobID: jobID)
          await self?.markCancelled(jobID: jobID, directory: directory)
        }
      } catch is CancellationError {
        if let outputURL {
          await self?.removeIncompleteOutput(at: outputURL, jobID: jobID)
        }
        await self?.markCancelled(jobID: jobID, directory: directory)
      } catch {
        if let outputURL {
          await self?.removeIncompleteOutput(at: outputURL, jobID: jobID)
        }
        await self?.markFailed(jobID: jobID, error: error, directory: directory)
      }
    }
  }

  private func updateProgress(_ line: TaskProgressLine, jobID: String) {
    guard jobs[jobID]?.status == "running", !isTerminating else { return }
    if line.id == "main" {
      taskProgress[jobID] = [line]
    } else {
      var lines = taskProgress[jobID, default: []].filter { $0.id != "main" }
      if let index = lines.firstIndex(where: { $0.id == line.id }) {
        lines[index] = line
      } else {
        lines.append(line)
      }
      taskProgress[jobID] = lines.sorted { $0.id < $1.id }
    }
  }

  private func markRunning(
    jobID: String, directory: URL, message: String = "原生引擎正在处理。"
  ) -> Bool {
    guard let job = jobs[jobID], job.status != "cancelled" else {
      tasks[jobID] = nil
      return false
    }
    let updated = replacing(
      job, status: "running", stage: "processing", message: message, progress: 12,
      logs: job.logs + ["开始使用 macOS 原生框架处理。"])
    do {
      try jobPersister(updated, directory)
      jobs[jobID] = updated
      taskProgress[jobID] = [TaskProgressLine(title: message)]
      return true
    } catch {
      jobs[jobID] = persistenceFailure(from: job, action: "无法保存任务启动状态", error: error)
      tasks[jobID] = nil
      appendPersistenceWarning(jobID: jobID, action: "保存任务启动状态", error: error)
      return false
    }
  }

  private func markCompleted(
    jobID: String, output: String, logs: [String], directory: URL
  ) -> Bool {
    guard let job = jobs[jobID], job.status != "cancelled" else { return false }
    tasks[jobID] = nil
    taskProgress[jobID] = nil
    var updated = replacing(
      job, status: "done", stage: "complete", message: "任务完成。", output: output,
      progress: 100, logs: job.logs + logs)
    do {
      try persistCompletionReceipt(output: output, in: directory)
    } catch {
      updated = appendingLog(
        "警告：结果已生成，但完成凭据未能保存：\(error.localizedDescription)", to: updated)
      appendPersistenceWarning(jobID: jobID, action: "保存任务完成凭据", error: error)
    }
    do {
      try jobPersister(updated, directory)
      jobs[jobID] = updated
    } catch {
      jobs[jobID] = appendingLog(
        "警告：结果已生成，但任务完成状态未能保存：\(error.localizedDescription)", to: updated)
      appendPersistenceWarning(jobID: jobID, action: "保存任务完成状态", error: error)
    }
    return true
  }

  private func removeIncompleteOutput(at outputURL: URL, jobID: String) async {
    let removal = Task.detached(priority: .utility) {
      do {
        try FileManager.default.removeItem(at: outputURL)
      } catch let error as CocoaError where error.code == .fileNoSuchFile {
        return
      }
    }
    do {
      try await removal.value
    } catch {
      appendLog(
        "任务 \(jobID.prefix(8)) 未能删除不完整结果：\(error.localizedDescription)")
    }
  }

  private func markCancelled(jobID: String, directory: URL) {
    tasks[jobID] = nil
    taskProgress[jobID] = nil
    guard !isTerminating else { return }
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let updated = replacing(
      job, status: "cancelled", stage: "cancelled", message: "任务已取消。", progress: job.progress,
      cancelRequested: true, logs: job.logs + ["任务已安全停止。"])
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
    tasks[jobID] = nil
    taskProgress[jobID] = nil
    guard let job = jobs[jobID], job.status != "cancelled" else { return }
    let nativeError = error as? NativeDocumentError
    let updated = replacing(
      job, status: "failed", stage: "failed", message: "任务失败。", error: error.localizedDescription,
      errorCode: nativeError?.code ?? "native_processing_failed",
      errorHint: nativeError?.recoverySuggestion ?? "检查输入文件和参数后重试。",
      retryable: true, progress: job.progress, logs: job.logs)
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
    let expectedOutput = OutputFileNamer.name(
      for: metadata.route, options: metadata.options, inputNames: metadata.inputNames)
    let receipt: NativeJobCompletionReceipt? = try? load("completion.json", from: directory)
    let outputURL = directory.appendingPathComponent(expectedOutput)
    if let receipt,
      JobStorage.completionReceiptMatches(
        receipt, expectedOutput: expectedOutput, outputURL: outputURL)
    {
      appendLog("已从完整结果恢复任务 \(job.id.prefix(8))，未重新执行处理。")
      return replacing(
        job, status: "done", stage: "complete", message: "任务完成。", output: expectedOutput,
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

  private func allowedExtensions(for source: String) -> Set<String> {
    Set(
      (NativeCapabilities.routes.first { $0.source == source }?.accept ?? "")
        .split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
        })
  }

  private func issue(
    _ code: String, _ message: String, hint: String? = nil
  ) -> PreflightIssue {
    PreflightIssue(code: code, dependency: nil, message: message, hint: hint)
  }

  private func jobDirectory(_ id: String) throws -> URL {
    guard let dataDirectory else {
      throw NativeDocumentError.processing("原生文档引擎尚未就绪。")
    }
    guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
      throw NativeDocumentError.invalidOption("任务编号无效。")
    }
    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    try JobStorage.validateDirectory(jobsDirectory, description: "任务数据目录")
    let directory = jobsDirectory.appendingPathComponent(id, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      throw NativeDocumentError.processing("找不到任务数据。")
    }
    try JobStorage.validateDirectory(directory, description: "任务目录")
    return directory
  }

  private func persistMetadata(_ metadata: NativeJobMetadata, in directory: URL) throws {
    let data = try JSONEncoder().encode(metadata)
    try JobStorage.validatePersistedDataSize(
      data, description: "任务元数据", maximumBytes: JobStorage.maximumJobMetadataBytes)
    try data.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
  }

  private func persistCompletionReceipt(output: String, in directory: URL) throws {
    let outputURL = try JobStorage.validatedRegularFile(
      named: output, in: directory, description: "任务结果")
    let fingerprint = try JobStorage.resultFingerprint(outputURL)
    let receipt = NativeJobCompletionReceipt(
      output: output, byteCount: fingerprint.byteCount,
      sampleSHA256: fingerprint.sampleSHA256)
    let data = try JSONEncoder().encode(receipt)
    try JobStorage.validatePersistedDataSize(
      data, description: "任务完成凭据", maximumBytes: JobStorage.maximumCompletionReceiptBytes)
    try data.write(to: directory.appendingPathComponent("completion.json"), options: .atomic)
  }

  private func load<T: Decodable>(_ name: String, from directory: URL) throws -> T {
    let maximumBytes: Int
    switch name {
    case "job.json": maximumBytes = JobStorage.maximumJobStateBytes
    case "metadata.json": maximumBytes = JobStorage.maximumJobMetadataBytes
    case "completion.json": maximumBytes = JobStorage.maximumCompletionReceiptBytes
    default:
      throw NativeDocumentError.invalidFile("任务状态文件名无效。")
    }
    let data = try JobStorage.boundedTaskFileData(
      named: name, in: directory, description: "任务状态文件", maximumBytes: maximumBytes)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private nonisolated static func preflightError(_ issue: PreflightIssue) -> NativeDocumentError {
    let message = [issue.message, issue.hint].compactMap { $0 }.joined(separator: "：")
    switch issue.code {
    case "missing_files", "too_many_files", "upload_too_large", "empty_file", "invalid_file_type":
      return .invalidFile(message)
    case "provider_not_configured", "provider_key_invalid", "provider_keychain_unavailable":
      return .provider(message)
    default:
      return .invalidOption(message)
    }
  }

  private func appendLog(_ text: String) {
    guard !text.isEmpty else { return }
    serviceLog.append(text)
    if serviceLog.count > 80 { serviceLog.removeFirst(serviceLog.count - 80) }
  }
}
