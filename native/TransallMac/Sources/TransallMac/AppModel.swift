import AppKit
import Combine
import Foundation
import SwiftUI

private struct DocumentImportError: LocalizedError, Sendable {
  let failures: [String]

  var errorDescription: String? {
    let visible = failures.prefix(8)
    var lines = ["无法导入所选文件："] + visible
    if failures.count > visible.count {
      lines.append("另有 \(failures.count - visible.count) 个文件未通过校验。")
    }
    return lines.joined(separator: "\n")
  }
}

@MainActor
final class AppModel: ObservableObject {
  typealias JobCreator = @MainActor (
    _ route: RouteDefinition, _ files: [SelectedDocument], _ options: JobOptions
  ) async throws -> JobResponse
  typealias ResultDestinationPicker = @MainActor (_ suggestedName: String) -> URL?
  typealias ResultDownloader = @MainActor (_ jobID: String, _ destination: URL) async throws -> Void
  typealias ResultRevealer = @MainActor (_ destination: URL) -> Void

  @Published var capabilities: CapabilitiesResponse?
  @Published var diagnostics: [String: DiagnosticDefinition] = [:]
  @Published var providers: [ProviderDefinition] = []
  @Published var selection = RouteSelection()
  @Published var documents: [SelectedDocument] = []
  @Published var options = JobOptions()
  @Published var currentJob: JobResponse?
  @Published var previewPages: [PreviewPage] = []
  @Published var previewError: String?
  @Published var preflightWarnings: [PreflightIssue] = []
  @Published var errorMessage: String?
  @Published private(set) var isImporting = false
  @Published var isSubmitting = false
  @Published private(set) var isSaving = false
  @Published var isDeletingJob = false
  @Published var isLoadingPreview = false
  @Published var showAdvanced = false
  private(set) var resultOriginalDocuments: [SelectedDocument] = []

  let backend: NativeDocumentEngine
  private var pollingTask: Task<Void, Never>?
  private var retentionCleanupTask: Task<Void, Never>?
  private var jobSubmissionTask: Task<Void, Never>?
  private var resultSaveTask: Task<Void, Never>?
  private var isStarting = false
  private var hasStarted = false
  private let preferences: UserDefaults
  private let jobCreator: JobCreator
  private let resultDestinationPicker: ResultDestinationPicker
  private let resultDownloader: ResultDownloader
  private let resultRevealer: ResultRevealer
  private let lastJobKey = "transall.native.lastJobId"

  convenience init() {
    self.init(backend: NativeDocumentEngine())
  }

  init(
    backend: NativeDocumentEngine, preferences: UserDefaults = .standard,
    jobCreator: JobCreator? = nil,
    resultDestinationPicker: ResultDestinationPicker? = nil,
    resultDownloader: ResultDownloader? = nil,
    resultRevealer: ResultRevealer? = nil
  ) {
    self.backend = backend
    self.preferences = preferences
    self.jobCreator =
      jobCreator ?? { route, files, options in
        try await backend.createJob(route: route, files: files, options: options)
      }
    self.resultDestinationPicker = resultDestinationPicker ?? Self.pickResultDestination
    self.resultDownloader =
      resultDownloader ?? { jobID, destination in
        try await backend.download(jobID: jobID, to: destination)
      }
    self.resultRevealer =
      resultRevealer ?? { destination in
        NSWorkspace.shared.activateFileViewerSelecting([destination])
      }
  }

  let formatOrder = [
    "pdf", "translated_pdf", "ocr", "md", "html", "image", "data",
  ]

  var route: RouteDefinition? {
    guard let source = selection.source, let target = selection.target else { return nil }
    return capabilities?.routes.first { $0.source == source && $0.target == target }
  }

  var canRun: Bool {
    route?.enabled == true
      && !documents.isEmpty
      && !isImporting
      && !isSubmitting
      && !isSaving
      && !isDeletingJob
      && currentJob?.isRunning != true
  }

  var canSelectDocuments: Bool {
    route?.enabled == true && !isImporting && !isSubmitting
  }

  var routeTitle: String {
    route?.title ?? "选择源格式和目标格式"
  }

  var hasPreviewableResult: Bool {
    currentJob?.status == "done" && currentJob?.output?.lowercased().hasSuffix(".pdf") == true
  }

  var canDeleteCurrentJob: Bool {
    guard let currentJob else { return false }
    return !currentJob.isRunning && !isSaving && !isDeletingJob
  }

  var inputLimitMB: Int {
    guard let route else { return capabilities?.limits.maxUploadMB ?? 250 }
    return NativeCapabilities.inputLimitMB(for: route)
  }

  var logText: String {
    var lines: [String] = []
    if let job = currentJob {
      if !job.stage.isEmpty { lines.append("阶段：\(job.stage)") }
      lines.append(contentsOf: job.logs)
      if let error = job.error { lines.append("错误：\(error)") }
      if let hint = job.errorHint { lines.append("建议：\(hint)") }
    } else {
      lines.append(contentsOf: backend.serviceLog.suffix(10))
    }
    return lines.isEmpty ? "等待任务。" : lines.joined(separator: "\n")
  }

  func start() async {
    guard !hasStarted, !isStarting else { return }
    isStarting = true
    defer { isStarting = false }
    if backend.state != .running {
      await backend.start()
    }
    guard !Task.isCancelled else { return }
    guard case .running = backend.state else { return }
    await reloadEnvironment()
    guard !Task.isCancelled else { return }
    await restoreLastJob()
    guard !Task.isCancelled else { return }
    beginRetentionCleanup()
    hasStarted = true
  }

  func reloadEnvironment() async {
    let capabilities = backend.capabilities()
    let environment = await backend.environment()
    guard !Task.isCancelled else { return }
    self.capabilities = capabilities
    self.diagnostics = Dictionary(
      uniqueKeysWithValues: environment.diagnostics.dependencies.map { ($0.name, $0) })
    providers = environment.providers.providers
    if !providers.contains(where: { $0.name == options.provider && $0.configured }),
      let configured = providers.first(where: \.configured)
    {
      options.provider = configured.name
    }
    errorMessage = nil
  }

  func chooseFormat(_ format: String, animated: Bool = true) {
    guard !isImporting else {
      errorMessage = "正在读取文件，请稍后再更换路径。"
      return
    }
    guard !isSubmitting else {
      errorMessage = "正在创建任务，请稍后再更换路径。"
      return
    }
    guard !isSaving else {
      errorMessage = "正在保存结果，请先取消保存再更换路径。"
      return
    }
    guard currentJob?.isRunning != true else {
      errorMessage = "任务运行中，请先取消任务再更换路径。"
      return
    }
    let changes = { [self] in
      selection.choose(format)
      documents = []
      preflightWarnings = []
      showAdvanced = false
    }
    if animated {
      withAnimation(.easeOut(duration: 0.32), changes)
    } else {
      changes()
    }
  }

  func resetRoute(animated: Bool = true) {
    guard !isImporting else {
      errorMessage = "正在读取文件，请稍后再重选路径。"
      return
    }
    guard !isSubmitting else {
      errorMessage = "正在创建任务，请稍后再重选路径。"
      return
    }
    guard !isSaving else {
      errorMessage = "正在保存结果，请先取消保存再重选路径。"
      return
    }
    guard currentJob?.isRunning != true else {
      errorMessage = "任务运行中，请先取消任务再重选路径。"
      return
    }
    pollingTask?.cancel()
    preferences.removeObject(forKey: lastJobKey)
    let changes = { [self] in
      selection.clear()
      documents = []
      currentJob = nil
      resultOriginalDocuments = []
      previewPages = []
      previewError = nil
      isLoadingPreview = false
      preflightWarnings = []
      errorMessage = nil
    }
    if animated {
      withAnimation(.easeOut(duration: 0.3), changes)
    } else {
      changes()
    }
  }

  func importDocuments(_ urls: [URL], appending: Bool = false) async {
    guard !urls.isEmpty else {
      errorMessage = "没有选择文件。"
      return
    }
    guard !isImporting else { return }
    guard !isSubmitting else {
      errorMessage = "正在创建任务，请稍后再修改输入文件。"
      return
    }
    guard route?.enabled == true else {
      errorMessage = "请先选择源格式和目标格式。"
      return
    }

    isImporting = true
    errorMessage = nil
    defer { isImporting = false }

    let inspection = Task.detached(priority: .userInitiated) {
      try Self.inspectDocuments(urls)
    }
    let imported: [SelectedDocument]
    do {
      imported = try await withTaskCancellationHandler(
        operation: { try await inspection.value },
        onCancel: { inspection.cancel() })
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    var combined = appending ? documents : []
    var existing = Set(combined.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
    combined.append(
      contentsOf: imported.filter {
        existing.insert($0.url.standardizedFileURL.resolvingSymlinksInPath()).inserted
      })

    let total = combined.reduce(Int64.zero) { partial, document in
      let (sum, overflow) = partial.addingReportingOverflow(document.size)
      return overflow ? Int64.max : sum
    }
    let limitBytes =
      route.map(NativeCapabilities.inputLimitBytes(for:))
      ?? capabilities?.limits.maxUploadBytes ?? NativeCapabilities.uploadLimitBytes
    if total > Int64(limitBytes) {
      errorMessage = "所选文件超过 \(inputLimitMB) MB 限制。"
      return
    }
    documents = combined
    errorMessage = nil
  }

  private nonisolated static func inspectDocuments(_ urls: [URL]) throws
    -> [SelectedDocument]
  {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    var imported: [SelectedDocument] = []
    var failures: [String] = []

    for url in urls {
      try Task.checkCancellation()
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      do {
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
          failures.append("\(url.lastPathComponent)：不支持符号链接，请选择原始文件。")
        } else if values.isRegularFile != true {
          failures.append("\(url.lastPathComponent)：不是普通文件。")
        } else if let size = values.fileSize {
          imported.append(SelectedDocument(url: url, size: Int64(size)))
        } else {
          failures.append("\(url.lastPathComponent)：无法读取文件大小。")
        }
      } catch {
        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
      }
    }

    guard failures.isEmpty else { throw DocumentImportError(failures: failures) }
    return imported
  }

  func removeDocument(_ document: SelectedDocument) {
    guard !isImporting, !isSubmitting else { return }
    documents.removeAll { $0.id == document.id }
  }

  func retryBackend() async {
    errorMessage = nil
    await start()
  }

  func applyCredentialChanges() async -> String {
    let message = await backend.applyCredentialChanges()
    if case .running = backend.state {
      await reloadEnvironment()
    }
    return message
  }

  func startJob() {
    guard jobSubmissionTask == nil, canRun, let route else { return }
    let submittedDocuments = documents
    let submittedOptions = options
    isSubmitting = true
    errorMessage = nil
    previewPages = []
    previewError = nil
    isLoadingPreview = false
    preflightWarnings = []

    jobSubmissionTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isSubmitting = false
        jobSubmissionTask = nil
      }
      await submitJob(
        route: route, documents: submittedDocuments, options: submittedOptions)
    }
  }

  func runJob() async {
    startJob()
    guard let jobSubmissionTask else { return }
    await jobSubmissionTask.value
  }

  func requestJobSubmissionCancellation() {
    jobSubmissionTask?.cancel()
  }

  func cancelJobSubmission() async {
    guard let jobSubmissionTask else { return }
    jobSubmissionTask.cancel()
    await jobSubmissionTask.value
  }

  private func submitJob(
    route: RouteDefinition, documents: [SelectedDocument], options: JobOptions
  ) async {
    var createdJob: JobResponse?
    do {
      try Task.checkCancellation()
      let preflight = await backend.preflight(
        route: route, files: documents, options: options)
      preflightWarnings = preflight.warnings
      guard preflight.ok else {
        errorMessage = preflight.blockingIssues
          .map { [$0.message, $0.hint].compactMap { $0 }.joined(separator: "：") }
          .joined(separator: "\n")
        return
      }

      try Task.checkCancellation()
      let job = try await jobCreator(route, documents, options)
      createdJob = job
      try Task.checkCancellation()
      currentJob = job
      resultOriginalDocuments = documents
      preferences.set(job.id, forKey: lastJobKey)
      beginPolling(jobID: job.id)
    } catch is CancellationError {
      guard let createdJob else { return }
      let cleanupTask = Task { [backend] in
        try await backend.discardJob(id: createdJob.id)
      }
      do {
        try await cleanupTask.value
      } catch {
        errorMessage = "任务创建已取消，但临时任务未能删除：\(error.localizedDescription)"
      }
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
    }
  }

  func cancelJob() async {
    guard let job = currentJob, job.isRunning else { return }
    do {
      currentJob = try backend.cancelJob(id: job.id)
      pollingTask?.cancel()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func startSavingResult() {
    guard resultSaveTask == nil, !isSaving, !isDeletingJob,
      let job = currentJob, job.status == "done", let output = job.output
    else { return }
    guard let destination = resultDestinationPicker(output) else { return }

    do {
      try ResultSavePolicy.validate(
        destination: destination, originalDocuments: resultOriginalDocuments)
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    errorMessage = nil
    isSaving = true
    resultSaveTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isSaving = false
        resultSaveTask = nil
      }
      do {
        try await resultDownloader(job.id, destination)
        try Task.checkCancellation()
        resultRevealer(destination)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = error.localizedDescription
      }
    }
  }

  func cancelResultSaving() async {
    guard let resultSaveTask else { return }
    resultSaveTask.cancel()
    await resultSaveTask.value
  }

  func refreshPreview() async {
    guard !isDeletingJob, let job = currentJob, hasPreviewableResult else { return }
    await loadPreview(jobID: job.id)
  }

  func deleteCurrentJob() async {
    guard canDeleteCurrentJob, let job = currentJob else { return }
    let jobID = job.id
    isDeletingJob = true
    defer { isDeletingJob = false }
    do {
      try await backend.deleteJob(id: jobID)
      clearJobState(id: jobID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func cleanupExpiredJobs(now: Date = Date()) async {
    guard !isSaving else { return }
    let removed = await backend.cleanupExpiredJobs(now: now)
    guard let currentJob, removed.contains(currentJob.id) else { return }
    pollingTask?.cancel()
    clearJobState(id: currentJob.id)
  }

  func prepareForTermination() {
    pollingTask?.cancel()
    retentionCleanupTask?.cancel()
    jobSubmissionTask?.cancel()
    resultSaveTask?.cancel()
    backend.prepareForTermination()
  }

  func diagnostic(for requirement: RouteRequirement) -> DiagnosticDefinition? {
    if ["deepseek", "openai"].contains(requirement.name) {
      return diagnostics[options.provider]
    }
    return diagnostics[requirement.name]
  }

  private func beginPolling(jobID: String) {
    pollingTask?.cancel()
    pollingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          let job = try backend.job(id: jobID)
          currentJob = job
          if job.isFinished {
            if job.status == "done" {
              await loadPreview(jobID: jobID)
            }
            return
          }
        } catch {
          errorMessage = error.localizedDescription
        }
        try? await Task.sleep(for: .milliseconds(900))
      }
    }
  }

  private func beginRetentionCleanup() {
    retentionCleanupTask?.cancel()
    retentionCleanupTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(60 * 60))
        } catch {
          return
        }
        guard let self else { return }
        await cleanupExpiredJobs()
      }
    }
  }

  private func clearJobState(id: String) {
    if preferences.string(forKey: lastJobKey) == id {
      preferences.removeObject(forKey: lastJobKey)
    }
    guard currentJob?.id == id else { return }
    currentJob = nil
    resultOriginalDocuments = []
    previewPages = []
    previewError = nil
    isLoadingPreview = false
    preflightWarnings = []
  }

  private func loadPreview(jobID: String) async {
    guard currentJob?.id == jobID else { return }
    isLoadingPreview = true
    previewError = nil
    defer {
      if currentJob?.id == jobID { isLoadingPreview = false }
    }
    do {
      let pages = try await backend.previewPages(jobID: jobID).pages
      guard currentJob?.id == jobID else { return }
      previewPages = pages
    } catch is CancellationError {
      return
    } catch {
      guard currentJob?.id == jobID else { return }
      previewPages = []
      previewError = "无法生成 PDF 预览：\(error.localizedDescription)"
    }
  }

  private func restoreLastJob() async {
    guard let jobID = preferences.string(forKey: lastJobKey) else { return }
    do {
      let job = try backend.job(id: jobID)
      currentJob = job
      if job.isRunning {
        beginPolling(jobID: job.id)
      } else if job.status == "done" {
        await loadPreview(jobID: job.id)
      }
    } catch {
      preferences.removeObject(forKey: lastJobKey)
    }
  }

  private static func pickResultDestination(suggestedName: String) -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.canCreateDirectories = true
    panel.message = ResultSavePolicy.panelMessage
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}
