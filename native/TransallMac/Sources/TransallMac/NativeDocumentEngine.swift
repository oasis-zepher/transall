import Combine
import CryptoKit
import Darwin
import Foundation

@MainActor
final class NativeDocumentEngine: ObservableObject {
  nonisolated static let maximumJobStateBytes = 1 * 1_024 * 1_024
  nonisolated static let maximumJobMetadataBytes = 128 * 1_024
  nonisolated static let maximumCompletionReceiptBytes = 16 * 1_024

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

  private struct CleanupScan: Sendable {
    let directories: [URL]
    let warnings: [String]
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
        try await Self.copyInputs(
          files, to: inputDirectory, maximumBytes: maximumBytes, maximumMB: maximumMB)
      }
    self.previewGenerator =
      previewGenerator ?? { pdfURL, directory in
        try await PreviewCache.pages(pdfURL: pdfURL, directory: directory)
      }
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
      providers: NativeCapabilities.providers(configured: status.configured))
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
          "provider_keychain_unavailable", "无法从 macOS 钥匙串读取翻译 API Key。",
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
    guard Self.canonicalRoute(matching: route) != nil else {
      blocking.append(
        issue(
          "unsupported_route", "此转换路径不属于当前原生版本。",
          hint: "请重新选择源格式和目标格式。"))
      return PreflightResponse(
        ok: false, blockingIssues: blocking, warnings: [], requirements: [])
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
    guard let canonicalRoute = Self.canonicalRoute(matching: route) else {
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
        try Self.validateStoredMetadata(metadata, for: job)
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
      (try? Self.validateStoredMetadata(metadata, for: persisted)) != nil
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
      try Self.expiredJobDirectories(in: jobsDirectory, now: now)
    }
    let scan: CleanupScan
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
      let verified = try Self.validatedCompletedResult(named: output, in: directory)
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
        let verified = try Self.validatedCompletedResult(named: output, in: directory)
        let pages = try await previewGenerator(verified.url, previewDirectory)
        _ = try Self.validatedCompletedResult(named: output, in: directory)
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

  func inspectionSnapshot(jobID: String) async throws -> DocumentInspectionSnapshot {
    let job = try job(id: jobID)
    guard !deletingJobs.contains(jobID), job.status == "done", let output = job.output,
      output.lowercased().hasSuffix(".pdf")
    else { throw NativeDocumentError.processing("这个任务没有可检查的 PDF 结果。") }
    let directory = try jobDirectory(jobID)
    let metadata: NativeJobMetadata = try load("metadata.json", from: directory)
    try Self.validateStoredMetadata(metadata, for: job)
    let operation = Task.detached(priority: .userInitiated) {
      let snapshotDirectory = directory.appendingPathComponent(
        "Inspection-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: snapshotDirectory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      var completed = false
      defer { if !completed { try? FileManager.default.removeItem(at: snapshotDirectory) } }
      let verified = try Self.validatedCompletedResult(named: output, in: directory)
      let result = snapshotDirectory.appendingPathComponent("result.pdf")
      try AtomicResultSaver.copyReplacing(
        source: verified.url, destination: result,
        expectedFingerprint: verified.fingerprint, allowReplacingExistingDestination: false)
      var original: URL?
      if metadata.inputNames.count == 1, let input = metadata.inputNames.first,
        input.lowercased().hasSuffix(".pdf")
      {
        let inputDirectory = directory.appendingPathComponent("Input", isDirectory: true)
        try Self.validateDirectory(inputDirectory, description: "任务输入目录")
        let source = try Self.validatedRegularFile(
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
      try Task.checkCancellation()
      completed = true
      return DocumentInspectionSnapshot(
        directory: snapshotDirectory, result: result, original: original)
    }
    return try await withTaskCancellationHandler(
      operation: { try await operation.value }, onCancel: { operation.cancel() })
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
              "无法从 macOS 钥匙串读取翻译 API Key：\(error.localizedDescription)")
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
        let expectedOutputURL = try Self.containedFileURL(
          named: OutputFileNamer.name(
            for: metadata.route, options: metadata.options, inputNames: metadata.inputNames),
          in: directory, description: "任务结果")
        outputURL = expectedOutputURL
        let inputURLs = try Self.validatedStoredInputs(
          named: metadata.inputNames, in: directory)
        let result = try await jobProcessor(
          metadata.route, inputURLs, metadata.options, expectedOutputURL, apiKey)
        try Task.checkCancellation()
        guard result.outputURL.standardizedFileURL == expectedOutputURL.standardizedFileURL else {
          throw NativeDocumentError.processing("处理器返回了意外的结果位置。")
        }
        guard Self.isCompleteResult(expectedOutputURL) else {
          throw NativeDocumentError.processing("处理器没有生成完整可用的结果。")
        }
        let accepted =
          await self?.markCompleted(
            jobID: jobID, output: expectedOutputURL.lastPathComponent, logs: result.logs,
            directory: directory) == true
        if !accepted {
          await self?.removeIncompleteOutput(at: expectedOutputURL, jobID: jobID)
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

  private func markRunning(jobID: String, directory: URL) -> Bool {
    guard let job = jobs[jobID], job.status != "cancelled" else {
      tasks[jobID] = nil
      return false
    }
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

  private func markCompleted(
    jobID: String, output: String, logs: [String], directory: URL
  ) -> Bool {
    tasks[jobID] = nil
    guard let job = jobs[jobID], job.status != "cancelled" else { return false }
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
      Self.completionReceiptMatches(
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

  nonisolated static func copyInputs(
    _ files: [SelectedDocument], to inputDirectory: URL, maximumBytes: Int, maximumMB: Int,
    chunkSize: Int = 1_024 * 1_024
  ) async throws -> [URL] {
    guard maximumBytes >= 0, chunkSize > 0 else {
      throw NativeDocumentError.invalidFile("输入文件复制限制无效。")
    }
    guard files.count <= NativeCapabilities.maximumInputFileCount else {
      throw NativeDocumentError.invalidFile(
        "每批最多处理 \(NativeCapabilities.maximumInputFileCount) 个文件，请拆分为多个任务。")
    }
    let transfer = Task.detached(priority: .userInitiated) {
      var copiedInputs: [URL] = []
      var removeCopiedInputs = true
      defer {
        if removeCopiedInputs {
          for copiedInput in copiedInputs {
            try? FileManager.default.removeItem(at: copiedInput)
          }
        }
      }
      var copiedBytes: Int64 = 0
      let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ]
      for (index, document) in files.enumerated() {
        try Task.checkCancellation()
        let safeName =
          "\(index + 1)-\(document.name.replacingOccurrences(of: "/", with: "-"))"
        let destination = try containedFileURL(
          named: safeName, in: inputDirectory, description: "输入文件")
        let accessing = document.url.startAccessingSecurityScopedResource()
        defer { if accessing { document.url.stopAccessingSecurityScopedResource() } }
        do {
          let sourceValues = try document.url.resourceValues(forKeys: resourceKeys)
          guard sourceValues.isSymbolicLink != true, sourceValues.isRegularFile == true else {
            throw NativeDocumentError.invalidFile(
              "\(document.name) 不是可复制的普通文件，请选择原始文件。")
          }

          let (sourceHandle, initialSourceStatus) = try SecureFileTransfer.openRegularSource(
            document.url,
            nonRegularMessage: "\(document.name) 不是可复制的普通文件，请选择原始文件。")
          defer { try? sourceHandle.close() }

          try Task.checkCancellation()
          let sourceSize = initialSourceStatus.st_size
          let maximum = Int64(maximumBytes)
          let (expectedTotal, expectedOverflow) = copiedBytes.addingReportingOverflow(sourceSize)
          guard !expectedOverflow, expectedTotal <= maximum else {
            throw NativeDocumentError.invalidFile(
              "复制后的文件总计超过 \(maximumMB) MB。")
          }

          var removeIncompleteDestination = true
          defer {
            if removeIncompleteDestination {
              try? FileManager.default.removeItem(at: destination)
            }
          }
          let destinationHandle = try SecureFileTransfer.openNewDestination(destination)
          defer { try? destinationHandle.close() }

          var fileBytes: Int64 = 0
          while true {
            try Task.checkCancellation()
            guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
              break
            }
            try Task.checkCancellation()
            let (newTotal, totalOverflow) = copiedBytes.addingReportingOverflow(
              Int64(chunk.count))
            guard !totalOverflow, newTotal <= maximum else {
              throw NativeDocumentError.invalidFile(
                "复制后的文件总计超过 \(maximumMB) MB。")
            }
            try destinationHandle.write(contentsOf: chunk)
            copiedBytes = newTotal
            fileBytes += Int64(chunk.count)
            try Task.checkCancellation()
            await Task.yield()
          }
          try destinationHandle.synchronize()
          try Task.checkCancellation()

          let sourceStatus = try SecureFileTransfer.fileStatus(for: sourceHandle.fileDescriptor)
          let copiedStatus = try SecureFileTransfer.fileStatus(
            for: destinationHandle.fileDescriptor)
          guard SecureFileTransfer.isUnchanged(initialSourceStatus, sourceStatus),
            sourceStatus.st_size == fileBytes
          else {
            throw NativeDocumentError.invalidFile(
              "\(document.name) 在复制过程中发生变化，请重新选择。")
          }
          guard SecureFileTransfer.isRegularFile(copiedStatus), copiedStatus.st_size == fileBytes
          else {
            throw NativeDocumentError.invalidFile(
              "\(document.name) 复制后不是有效的普通文件。")
          }
          removeIncompleteDestination = false
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as NativeDocumentError {
          throw error
        } catch {
          throw NativeDocumentError.invalidFile(
            "无法读取 \(document.name)：\(error.localizedDescription)")
        }
        copiedInputs.append(destination)
      }
      removeCopiedInputs = false
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
    let scan = try expiredJobDirectories(in: jobsDirectory, now: Date())
    var warnings = scan.warnings
    for directory in scan.directories {
      try Task.checkCancellation()
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        warnings.append("未能清理过期任务 \(directory.lastPathComponent)：\(error.localizedDescription)")
      }
    }
    return (directory, warnings)
  }

  private nonisolated static func expiredJobDirectories(
    in jobsDirectory: URL, now: Date
  ) throws -> CleanupScan {
    try validateDirectory(jobsDirectory, description: "任务数据目录")
    let directories = try FileManager.default.contentsOfDirectory(
      at: jobsDirectory,
      includingPropertiesForKeys: [
        .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
      ],
      options: [.skipsHiddenFiles])
    let dateFormatter = ISO8601DateFormatter()
    var expired: [URL] = []
    var warnings: [String] = []
    for directory in directories {
      try Task.checkCancellation()
      do {
        let values = try directory.resourceValues(
          forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isDirectory == true,
          let modified = values.contentModificationDate
        else { continue }
        let referenceDate = cleanupReferenceDate(
          in: directory, fallback: modified, now: now, dateFormatter: dateFormatter)
        guard now.timeIntervalSince(referenceDate) >= 24 * 60 * 60 else { continue }
        expired.append(directory)
      } catch {
        warnings.append("无法检查任务 \(directory.lastPathComponent) 的保留期：\(error.localizedDescription)")
      }
    }
    return CleanupScan(directories: expired, warnings: warnings)
  }

  private nonisolated static func cleanupReferenceDate(
    in directory: URL, fallback: Date, now: Date, dateFormatter: ISO8601DateFormatter
  ) -> Date {
    guard
      let data = try? boundedTaskFileData(
        named: "job.json", in: directory, description: "任务状态文件",
        maximumBytes: maximumJobStateBytes),
      let job = try? JSONDecoder().decode(JobResponse.self, from: data),
      job.id == directory.lastPathComponent,
      let createdAt = dateFormatter.date(from: job.createdAt),
      createdAt <= now.addingTimeInterval(5 * 60)
    else {
      return fallback
    }
    return createdAt
  }

  private func jobDirectory(_ id: String) throws -> URL {
    guard let dataDirectory else {
      throw NativeDocumentError.processing("原生文档引擎尚未就绪。")
    }
    guard UUID(uuidString: id)?.uuidString.lowercased() == id else {
      throw NativeDocumentError.invalidOption("任务编号无效。")
    }
    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    try Self.validateDirectory(jobsDirectory, description: "任务数据目录")
    let directory = jobsDirectory.appendingPathComponent(id, isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      throw NativeDocumentError.processing("找不到任务数据。")
    }
    try Self.validateDirectory(directory, description: "任务目录")
    return directory
  }

  private func persistMetadata(_ metadata: NativeJobMetadata, in directory: URL) throws {
    let data = try JSONEncoder().encode(metadata)
    try Self.validatePersistedDataSize(
      data, description: "任务元数据", maximumBytes: Self.maximumJobMetadataBytes)
    try data.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
  }

  private func persistCompletionReceipt(output: String, in directory: URL) throws {
    let outputURL = try Self.validatedRegularFile(
      named: output, in: directory, description: "任务结果")
    let fingerprint = try Self.resultFingerprint(outputURL)
    let receipt = NativeJobCompletionReceipt(
      output: output, byteCount: fingerprint.byteCount,
      sampleSHA256: fingerprint.sampleSHA256)
    let data = try JSONEncoder().encode(receipt)
    try Self.validatePersistedDataSize(
      data, description: "任务完成凭据", maximumBytes: Self.maximumCompletionReceiptBytes)
    try data.write(to: directory.appendingPathComponent("completion.json"), options: .atomic)
  }

  private nonisolated static func persistJob(_ job: JobResponse, in directory: URL) throws {
    let data = try JSONEncoder().encode(job)
    try validatePersistedDataSize(
      data, description: "任务状态", maximumBytes: maximumJobStateBytes)
    try data.write(to: directory.appendingPathComponent("job.json"), options: .atomic)
  }

  private nonisolated static func isCompleteResult(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isSymbolicLink != true, values.isRegularFile == true
    else {
      return false
    }
    if url.pathExtension.lowercased() == "pdf" {
      return ((try? NativeDocumentProcessor.previewPageCount(pdfURL: url, limit: 1)) ?? 0) > 0
    }
    return true
  }

  private nonisolated static func completionReceiptMatches(
    _ receipt: NativeJobCompletionReceipt, expectedOutput: String, outputURL: URL
  ) -> Bool {
    guard receipt.output == expectedOutput, let expected = fingerprint(from: receipt),
      isCompleteResult(outputURL),
      let fingerprint = try? resultFingerprint(outputURL)
    else {
      return false
    }
    return fingerprint == expected
  }

  private nonisolated static func validatedCompletedResult(
    named output: String, in directory: URL
  ) throws -> (url: URL, fingerprint: CompletedResultFingerprint) {
    let outputURL = try validatedRegularFile(
      named: output, in: directory, description: "任务结果")
    let receipt: NativeJobCompletionReceipt
    do {
      let data = try boundedTaskFileData(
        named: "completion.json", in: directory, description: "任务完成凭据",
        maximumBytes: maximumCompletionReceiptBytes)
      receipt = try JSONDecoder().decode(NativeJobCompletionReceipt.self, from: data)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw NativeDocumentError.invalidFile("任务完成凭据缺失或无效，请重新运行任务。")
    }
    guard receipt.output == output, let expected = fingerprint(from: receipt),
      isCompleteResult(outputURL), try resultFingerprint(outputURL) == expected
    else {
      throw NativeDocumentError.invalidFile("任务结果与完成凭据不一致，请重新运行任务。")
    }
    return (outputURL, expected)
  }

  private nonisolated static func fingerprint(
    from receipt: NativeJobCompletionReceipt
  ) -> CompletedResultFingerprint? {
    guard let byteCount = receipt.byteCount, byteCount >= 0,
      let sampleSHA256 = receipt.sampleSHA256, sampleSHA256.count == 64,
      sampleSHA256.allSatisfy({ $0.isHexDigit })
    else { return nil }
    return CompletedResultFingerprint(byteCount: byteCount, sampleSHA256: sampleSHA256)
  }

  private nonisolated static func resultFingerprint(_ url: URL) throws
    -> CompletedResultFingerprint
  {
    let sampleSize = 64 * 1_024
    let (handle, initialStatus) = try SecureFileTransfer.openRegularSource(
      url, nonRegularMessage: "任务结果不是有效的普通文件。")
    defer { try? handle.close() }
    let fileSize = initialStatus.st_size
    var sample = Data()
    if fileSize <= Int64(sampleSize * 2) {
      sample = try handle.readToEnd() ?? Data()
      guard Int64(sample.count) == fileSize else {
        throw NativeDocumentError.processing("任务结果大小在验证期间发生变化。")
      }
    } else {
      let prefix = try handle.read(upToCount: sampleSize) ?? Data()
      try handle.seek(toOffset: UInt64(fileSize - Int64(sampleSize)))
      let suffix = try handle.read(upToCount: sampleSize) ?? Data()
      guard prefix.count == sampleSize, suffix.count == sampleSize else {
        throw NativeDocumentError.processing("任务结果大小在验证期间发生变化。")
      }
      sample.append(prefix)
      sample.append(suffix)
    }
    let finalStatus = try SecureFileTransfer.fileStatus(for: handle.fileDescriptor)
    guard SecureFileTransfer.isUnchanged(initialStatus, finalStatus) else {
      throw NativeDocumentError.processing("任务结果在验证期间发生变化。")
    }
    let digest = SHA256.hash(data: sample).map { String(format: "%02x", $0) }.joined()
    return CompletedResultFingerprint(byteCount: fileSize, sampleSHA256: digest)
  }

  private func load<T: Decodable>(_ name: String, from directory: URL) throws -> T {
    let maximumBytes: Int
    switch name {
    case "job.json": maximumBytes = Self.maximumJobStateBytes
    case "metadata.json": maximumBytes = Self.maximumJobMetadataBytes
    case "completion.json": maximumBytes = Self.maximumCompletionReceiptBytes
    default:
      throw NativeDocumentError.invalidFile("任务状态文件名无效。")
    }
    let data = try Self.boundedTaskFileData(
      named: name, in: directory, description: "任务状态文件", maximumBytes: maximumBytes)
    return try JSONDecoder().decode(T.self, from: data)
  }

  private nonisolated static func validatePersistedDataSize(
    _ data: Data, description: String, maximumBytes: Int
  ) throws {
    guard data.count <= maximumBytes else {
      throw NativeDocumentError.invalidFile("\(description)超过大小限制。")
    }
  }

  private nonisolated static func boundedTaskFileData(
    named name: String, in directory: URL, description: String, maximumBytes: Int
  ) throws -> Data {
    guard maximumBytes >= 0 else {
      throw NativeDocumentError.invalidFile("\(description)大小限制无效。")
    }
    let url = try containedFileURL(named: name, in: directory, description: description)
    let (handle, initialStatus) = try SecureFileTransfer.openRegularSource(
      url, nonRegularMessage: "\(description)不是有效的普通文件。")
    defer { try? handle.close() }
    guard initialStatus.st_size <= Int64(maximumBytes) else {
      throw NativeDocumentError.invalidFile("\(description)超过大小限制，数据可能已经损坏。")
    }

    var data = Data()
    data.reserveCapacity(Int(initialStatus.st_size))
    let readChunkBytes = 64 * 1_024
    while true {
      try Task.checkCancellation()
      let remaining = maximumBytes - data.count
      let requestedBytes = min(readChunkBytes, remaining + 1)
      guard let chunk = try handle.read(upToCount: requestedBytes), !chunk.isEmpty else {
        break
      }
      guard chunk.count <= remaining else {
        throw NativeDocumentError.invalidFile("\(description)超过大小限制，数据可能已经损坏。")
      }
      data.append(chunk)
    }

    let finalStatus = try SecureFileTransfer.fileStatus(for: handle.fileDescriptor)
    guard SecureFileTransfer.isUnchanged(initialStatus, finalStatus),
      finalStatus.st_size == Int64(data.count)
    else {
      throw NativeDocumentError.invalidFile("\(description)在读取期间发生变化，数据可能已经损坏。")
    }
    return data
  }

  private nonisolated static func validateStoredInputNames(_ names: [String]) throws {
    guard !names.isEmpty else {
      throw NativeDocumentError.invalidFile("任务没有可恢复的输入文件。")
    }
    guard names.count <= NativeCapabilities.maximumInputFileCount else {
      throw NativeDocumentError.invalidFile(
        "任务输入超过每批最多 \(NativeCapabilities.maximumInputFileCount) 个文件的限制。")
    }
    guard Set(names).count == names.count else {
      throw NativeDocumentError.invalidFile("任务输入列表包含重复文件，数据可能已经损坏。")
    }
    for name in names {
      guard isSafeFileName(name) else {
        throw NativeDocumentError.invalidFile("任务输入文件名无效，数据可能已经损坏。")
      }
    }
  }

  private nonisolated static func validateStoredMetadata(
    _ metadata: NativeJobMetadata, for job: JobResponse
  ) throws {
    guard canonicalRoute(matching: metadata.route) != nil, metadata.route.kind == job.kind else {
      throw NativeDocumentError.invalidFile("任务路径与任务状态不一致，数据可能已经损坏。")
    }
    try validateStoredInputNames(metadata.inputNames)
    try JobOptionValidator.validate(route: metadata.route, options: metadata.options)
    if metadata.route.kind == "pdf_edit", metadata.options.editAction == "merge",
      metadata.inputNames.count < 2
    {
      throw NativeDocumentError.invalidFile("合并 PDF 的持久化任务缺少输入文件。")
    }
    if metadata.route.kind == "pdf_edit", metadata.options.editAction != "merge",
      metadata.inputNames.count != 1
    {
      throw NativeDocumentError.invalidFile("单个 PDF 编辑任务的输入数量无效。")
    }
    if metadata.route.kind == "pdf_translate", metadata.inputNames.count != 1 {
      throw NativeDocumentError.invalidFile("PDF 翻译任务的输入数量无效。")
    }
  }

  private nonisolated static func canonicalRoute(
    matching route: RouteDefinition
  ) -> RouteDefinition? {
    guard route.enabled else { return nil }
    return NativeCapabilities.routes.first {
      $0.enabled && $0.source == route.source && $0.target == route.target && $0.kind == route.kind
    }
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

  private nonisolated static func validatedStoredInputs(
    named names: [String], in jobDirectory: URL
  ) throws -> [URL] {
    try validateStoredInputNames(names)
    let inputDirectory = jobDirectory.appendingPathComponent("Input", isDirectory: true)
    try validateDirectory(inputDirectory, description: "任务输入目录")
    return try names.map {
      try validatedRegularFile(named: $0, in: inputDirectory, description: "任务输入")
    }
  }

  private nonisolated static func validatedRegularFile(
    named name: String, in directory: URL, description: String
  ) throws -> URL {
    let url = try containedFileURL(named: name, in: directory, description: description)
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    } catch {
      throw NativeDocumentError.invalidFile("\(description)不可读取：\(error.localizedDescription)")
    }
    guard values.isSymbolicLink != true, values.isRegularFile == true else {
      throw NativeDocumentError.invalidFile("\(description)不是有效的普通文件。")
    }
    return url
  }

  private nonisolated static func containedFileURL(
    named name: String, in directory: URL, description: String
  ) throws -> URL {
    guard isSafeFileName(name) else {
      throw NativeDocumentError.invalidFile("\(description)的文件名无效。")
    }
    let standardizedDirectory = directory.standardizedFileURL
    let url = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL
    guard url.deletingLastPathComponent() == standardizedDirectory else {
      throw NativeDocumentError.invalidFile("\(description)超出任务目录。")
    }
    return url
  }

  private nonisolated static func isSafeFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
      && URL(fileURLWithPath: name).lastPathComponent == name
  }

  private nonisolated static func validateDirectory(_ url: URL, description: String) throws {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch {
      throw NativeDocumentError.invalidFile("\(description)不可读取：\(error.localizedDescription)")
    }
    guard values.isSymbolicLink != true, values.isDirectory == true else {
      throw NativeDocumentError.invalidFile("\(description)不是有效目录。")
    }
  }

  private func appendLog(_ text: String) {
    guard !text.isEmpty else { return }
    serviceLog.append(text)
    if serviceLog.count > 80 { serviceLog.removeFirst(serviceLog.count - 80) }
  }
}

struct CompletedResultFingerprint: Equatable, Sendable {
  let byteCount: Int64
  let sampleSHA256: String
}

private enum SecureFileTransfer {
  static func openRegularSource(
    _ source: URL, nonRegularMessage: String
  ) throws -> (handle: FileHandle, status: stat) {
    var openError = Int32(EINVAL)
    let descriptor = source.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      let result = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      if result < 0 { openError = errno }
      return result
    }
    guard descriptor >= 0 else {
      if openError == ELOOP {
        throw NativeDocumentError.invalidFile(nonRegularMessage)
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
    }

    do {
      let status = try fileStatus(for: descriptor)
      guard isRegularFile(status), status.st_size >= 0 else {
        throw NativeDocumentError.invalidFile(nonRegularMessage)
      }
      return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), status)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  static func openNewDestination(_ destination: URL) throws -> FileHandle {
    var openError = Int32(EINVAL)
    let descriptor = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      let result = Darwin.open(
        path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(S_IRUSR | S_IWUSR))
      if result < 0 { openError = errno }
      return result
    }
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  static func fileStatus(for descriptor: Int32) throws -> stat {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return status
  }

  static func isRegularFile(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
  }

  static func isUnchanged(_ initial: stat, _ final: stat) -> Bool {
    isRegularFile(final) && initial.st_dev == final.st_dev && initial.st_ino == final.st_ino
      && initial.st_size == final.st_size
      && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
      && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
      && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
      && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
  }
}

enum AtomicResultSaver {
  static func copyReplacing(
    source: URL, destination: URL, chunkSize: Int = 1_024 * 1_024,
    expectedFingerprint: CompletedResultFingerprint? = nil,
    allowReplacingExistingDestination: Bool = true
  ) throws {
    guard source.isFileURL, destination.isFileURL else {
      throw ResultSaveError.invalidDestination
    }
    guard chunkSize > 0 else {
      throw NativeDocumentError.invalidFile("结果保存分块大小无效。")
    }
    let manager = FileManager.default
    if !allowReplacingExistingDestination, manager.fileExists(atPath: destination.path) {
      throw ResultSaveError.restoredTaskExistingDestination
    }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".transall-save-\(UUID().uuidString)", isDirectory: false)
    var removeTemporary = true
    defer {
      if removeTemporary {
        try? manager.removeItem(at: temporary)
      }
    }

    try Task.checkCancellation()
    let (sourceHandle, initialSourceStatus) = try SecureFileTransfer.openRegularSource(
      source, nonRegularMessage: "任务结果不是有效的普通文件。")
    defer { try? sourceHandle.close() }

    let destinationHandle = try SecureFileTransfer.openNewDestination(temporary)
    var destinationClosed = false
    defer {
      if !destinationClosed { try? destinationHandle.close() }
    }

    var copiedBytes: Int64 = 0
    let sampleSize = 64 * 1_024
    var smallResultSample = Data()
    var firstSample = Data()
    var lastSample = Data()
    var canUseCompleteSample = true
    while true {
      try Task.checkCancellation()
      guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
        break
      }
      try Task.checkCancellation()
      let (newTotal, overflow) = copiedBytes.addingReportingOverflow(Int64(chunk.count))
      guard !overflow else {
        throw NativeDocumentError.invalidFile("任务结果过大，无法保存。")
      }
      if expectedFingerprint != nil {
        if canUseCompleteSample, newTotal <= Int64(sampleSize * 2) {
          smallResultSample.append(chunk)
        } else {
          canUseCompleteSample = false
          smallResultSample.removeAll(keepingCapacity: false)
        }
        if firstSample.count < sampleSize {
          firstSample.append(chunk.prefix(sampleSize - firstSample.count))
        }
        if chunk.count >= sampleSize {
          lastSample = Data(chunk.suffix(sampleSize))
        } else {
          lastSample.append(chunk)
          if lastSample.count > sampleSize {
            lastSample.removeFirst(lastSample.count - sampleSize)
          }
        }
      }
      try destinationHandle.write(contentsOf: chunk)
      copiedBytes = newTotal
      try Task.checkCancellation()
    }
    if let expectedFingerprint {
      var sample = canUseCompleteSample ? smallResultSample : firstSample
      if !canUseCompleteSample { sample.append(lastSample) }
      let digest = SHA256.hash(data: sample).map { String(format: "%02x", $0) }.joined()
      let actual = CompletedResultFingerprint(
        byteCount: copiedBytes, sampleSHA256: digest)
      guard actual == expectedFingerprint else {
        throw NativeDocumentError.invalidFile(
          "任务结果与完成凭据不一致，未保存结果。请重新运行任务。")
      }
    }
    try destinationHandle.synchronize()
    try Task.checkCancellation()

    let finalSourceStatus = try SecureFileTransfer.fileStatus(for: sourceHandle.fileDescriptor)
    let copiedStatus = try SecureFileTransfer.fileStatus(
      for: destinationHandle.fileDescriptor)
    guard SecureFileTransfer.isUnchanged(initialSourceStatus, finalSourceStatus),
      finalSourceStatus.st_size == copiedBytes
    else {
      throw NativeDocumentError.invalidFile("任务结果在保存期间发生变化，请重新保存。")
    }
    guard SecureFileTransfer.isRegularFile(copiedStatus), copiedStatus.st_size == copiedBytes
    else {
      throw NativeDocumentError.invalidFile("结果副本保存不完整，请重试。")
    }

    try destinationHandle.close()
    destinationClosed = true
    try Task.checkCancellation()
    if allowReplacingExistingDestination {
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: destination)
      }
    } else {
      try moveExclusively(temporary, to: destination)
    }
    removeTemporary = false
  }

  private static func moveExclusively(_ source: URL, to destination: URL) throws {
    var renameError = Int32(EINVAL)
    let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
      guard let sourcePath else { return -1 }
      return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
        guard let destinationPath else { return -1 }
        let result = renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
        if result < 0 { renameError = errno }
        return result
      }
    }
    guard result == 0 else {
      if renameError == EEXIST {
        throw ResultSaveError.restoredTaskExistingDestination
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError))
    }
  }
}

enum ResultSavePolicy {
  static let panelMessage =
    "处理过程不会修改原始文件；不能把结果存回本次任务的原文件。恢复的任务只能保存为新文件。替换其他已有文件时，macOS 会先要求确认。"

  static func validate(destination: URL, originalDocuments: [SelectedDocument]?) throws {
    guard destination.isFileURL else {
      throw ResultSaveError.invalidDestination
    }
    guard let originalDocuments else {
      if FileManager.default.fileExists(atPath: destination.path) {
        throw ResultSaveError.restoredTaskExistingDestination
      }
      return
    }
    for document in originalDocuments where refersToSameFile(destination, document.url) {
      throw ResultSaveError.originalFile
    }
  }

  private static func refersToSameFile(_ first: URL, _ second: URL) -> Bool {
    let firstResolved = first.standardizedFileURL.resolvingSymlinksInPath()
    let secondResolved = second.standardizedFileURL.resolvingSymlinksInPath()
    if firstResolved.path == secondResolved.path { return true }

    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    guard
      let firstIdentifier = try? firstResolved.resourceValues(forKeys: keys)
        .fileResourceIdentifier as? AnyHashable,
      let secondIdentifier = try? secondResolved.resourceValues(forKeys: keys)
        .fileResourceIdentifier as? AnyHashable
    else { return false }
    return firstIdentifier == secondIdentifier
  }
}

enum ResultSaveError: LocalizedError {
  case invalidDestination
  case originalFile
  case restoredTaskExistingDestination

  var errorDescription: String? {
    switch self {
    case .invalidDestination:
      "只能把结果保存为本机文件。"
    case .originalFile:
      "不能覆盖本次任务的原始文件。请选择其他位置或文件名。"
    case .restoredTaskExistingDestination:
      "恢复的任务无法确认原文件身份，不能替换已有文件。请选择新文件名或其他空位置。"
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
    try discardUnsafeCacheEntry(at: directory)
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

    try discardCache(at: directory)
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
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? [])
      .filter { $0.pathExtension.lowercased() == "png" }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
  }

  private static func isComplete(_ urls: [URL], expectedCount: Int) -> Bool {
    guard urls.count == expectedCount else { return false }
    return urls.enumerated().allSatisfy { index, url in
      guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
        return false
      }
      guard
        let values = try? url.resourceValues(
          forKeys: [.isRegularFileKey])
      else { return false }
      return url.lastPathComponent == "page-\(index + 1).png"
        && values.isRegularFile == true
        && NativeDocumentProcessor.isReadableImage(url)
    }
  }

  private static func discardUnsafeCacheEntry(at directory: URL) throws {
    let manager = FileManager.default
    if (try? manager.destinationOfSymbolicLink(atPath: directory.path)) != nil {
      try manager.removeItem(atPath: directory.path)
      return
    }
    var isDirectory = ObjCBool(false)
    if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue
    {
      try manager.removeItem(atPath: directory.path)
    }
  }

  private static func discardCache(at directory: URL) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }
}

private struct NativeJobMetadata: Codable {
  let route: RouteDefinition
  let options: JobOptions
  let inputNames: [String]
}

private struct NativeJobCompletionReceipt: Codable {
  let output: String
  let byteCount: Int64?
  let sampleSHA256: String?
}
