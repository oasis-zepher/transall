import AppKit
import Combine
import Foundation
import SwiftUI

struct DocumentImportError: LocalizedError, Sendable {
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

enum RouteChangeLock: Equatable {
  case importing
  case submitting
  case saving
  case running
  case deleting

  var statusLabel: String {
    switch self {
    case .importing: "正在读取文件"
    case .submitting: "正在创建任务"
    case .saving: "正在保存结果"
    case .running: "任务运行中"
    case .deleting: "正在删除任务"
    }
  }

  var helpText: String {
    switch self {
    case .importing: "正在读取文件，完成后可以更换路径"
    case .submitting: "正在创建任务，完成后可以更换路径"
    case .saving: "先取消正在进行的结果保存"
    case .running: "先取消正在运行的任务"
    case .deleting: "任务删除完成后可以更换任务"
    }
  }

  func errorMessage(reset: Bool) -> String {
    let action = reset ? "重选" : "更换"
    return switch self {
    case .importing: "正在读取文件，请稍后再\(action)路径。"
    case .submitting: "正在创建任务，请稍后再\(action)路径。"
    case .saving: "正在保存结果，请先取消保存再\(action)路径。"
    case .running: "任务运行中，请先取消任务再\(action)路径。"
    case .deleting: "正在删除任务，请稍后再\(action)任务。"
    }
  }
}

struct TranslationRecoverySummary: Equatable {
  let jobID: String
  let regionCount: Int
  let issueCount: Int
  let issuePages: [Int]
  var completedRegionCount: Int? = nil

  var isComplete: Bool { completedRegionCount == nil || completedRegionCount == regionCount }
}

@MainActor
final class AppModel: ObservableObject {
  typealias JobCreator =
    @MainActor (
      _ route: RouteDefinition, _ files: [SelectedDocument], _ options: JobOptions
    ) async throws -> JobResponse
  typealias ResultDestinationPicker = @MainActor (_ suggestedName: String) -> URL?
  typealias ResultDownloader =
    @MainActor (
      _ jobID: String, _ destination: URL, _ allowReplacingExistingDestination: Bool
    ) async throws -> Void
  typealias ResultRevealer = @MainActor (_ destination: URL) -> Void
  typealias DocumentInspector = @Sendable ([URL]) async throws -> [SelectedDocument]

  @Published var capabilities: CapabilitiesResponse?
  @Published var diagnostics: [String: DiagnosticDefinition] = [:]
  @Published var providers: [ProviderDefinition] = []
  @Published var selection = RouteSelection()
  @Published var showInputPreview = false
  @Published var selectedDocumentID: URL? {
    didSet { if selectedDocumentID != nil { showInputPreview = true } }
  }
  @Published var documents: [SelectedDocument] = [] {
    didSet {
      if !documents.contains(where: { $0.id == selectedDocumentID }) {
        selectedDocumentID = documents.first?.id
      }
    }
  }
  @Published var options = JobOptions()
  @Published var currentJob: JobResponse? {
    didSet {
      if currentJob?.id != oldValue?.id || currentJob?.status != oldValue?.status {
        clearTranslationRecovery()
        if currentJob?.status == "done" { showInputPreview = false }
      }
    }
  }
  @Published var translationRecovery: TranslationRecoverySummary?
  @Published var translationRecoveryError: String?
  @Published var isLoadingTranslationRecovery = false
  var recoveryLoadID = UUID()
  @Published var previewPages: [PreviewPage] = []
  @Published var previewError: String?
  @Published var preflightWarnings: [PreflightIssue] = []
  @Published var errorMessage: String?
  @Published var isImporting = false
  @Published var isSubmitting = false
  @Published var isSaving = false
  @Published var isDeletingJob = false
  @Published var isLoadingPreview = false
  @Published var showAdvanced = false
  @Published var inspectionPage = 1
  var resultOriginalDocuments: [SelectedDocument]?

  let backend: NativeDocumentEngine
  var pollingTask: Task<Void, Never>?
  private var retentionCleanupTask: Task<Void, Never>?
  var documentImportTask: Task<Void, Never>?
  private var jobSubmissionTask: Task<Void, Never>?
  var resultSaveTask: Task<Void, Never>?
  private var isStarting = false
  private var hasStarted = false
  let preferences: UserDefaults
  private let jobCreator: JobCreator
  let resultDestinationPicker: ResultDestinationPicker?
  var resultSavePanel: NSSavePanel?
  let resultDownloader: ResultDownloader
  let resultRevealer: ResultRevealer
  let documentInspector: DocumentInspector
  let lastJobKey = "transall.native.lastJobId"

  convenience init() {
    self.init(backend: NativeDocumentEngine())
  }

  init(
    backend: NativeDocumentEngine, preferences: UserDefaults = .standard,
    jobCreator: JobCreator? = nil,
    resultDestinationPicker: ResultDestinationPicker? = nil,
    resultDownloader: ResultDownloader? = nil,
    resultRevealer: ResultRevealer? = nil,
    documentInspector: DocumentInspector? = nil
  ) {
    self.backend = backend
    self.preferences = preferences
    self.jobCreator =
      jobCreator ?? { route, files, options in
        try await backend.createJob(route: route, files: files, options: options)
      }
    self.resultDestinationPicker = resultDestinationPicker
    self.resultDownloader =
      resultDownloader ?? { jobID, destination, allowReplacingExistingDestination in
        try await backend.download(
          jobID: jobID, to: destination,
          allowReplacingExistingDestination: allowReplacingExistingDestination)
      }
    self.resultRevealer =
      resultRevealer ?? { destination in
        NSWorkspace.shared.activateFileViewerSelecting([destination])
      }
    self.documentInspector =
      documentInspector ?? { urls in
        let inspection = Task.detached(priority: .userInitiated) {
          try Self.inspectDocuments(urls)
        }
        return try await withTaskCancellationHandler(
          operation: { try await inspection.value },
          onCancel: { inspection.cancel() })
      }
  }

  var selectedTask: WorkbenchTask { WorkbenchTask.matching(selection) ?? .editPDF }

  func selectTask(_ task: WorkbenchTask, source: String? = nil) {
    guard canChangeRoute else { return }
    let next = task.selection(source: source)
    guard next != selection else { return }
    resetRoute(animated: false)
    selection = next
    options = JobOptions()
    if let provider = providers.first(where: \.configured) { options.provider = provider.name }
    showAdvanced = false
  }

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

  var routeChangeLock: RouteChangeLock? {
    if isImporting { return .importing }
    if isSubmitting { return .submitting }
    if isSaving { return .saving }
    if isDeletingJob { return .deleting }
    if currentJob?.isRunning == true { return .running }
    return nil
  }

  var canChangeRoute: Bool {
    routeChangeLock == nil
  }

  var canSelectDocuments: Bool {
    route?.enabled == true && !isImporting && canEditTaskDraft
      && documents.count < NativeCapabilities.maximumInputFileCount
  }

  var canEditTaskDraft: Bool {
    taskDraftLockMessage == nil
  }

  var taskDraftLockMessage: String? {
    if isSaving { return "正在保存结果，完成后可修改文件和参数" }
    if isDeletingJob { return "正在删除任务，完成后可修改文件和参数" }
    if isSubmitting { return "正在创建任务，完成后可修改文件和参数" }
    if currentJob?.isRunning == true { return "任务运行中，完成或取消后可修改文件和参数" }
    return nil
  }

  var routeTitle: String {
    route?.title ?? "选择任务"
  }

  var hasPreviewableResult: Bool {
    currentJob?.status == "done" && currentJob?.output?.lowercased().hasSuffix(".pdf") == true
  }

  var canRecoverTranslation: Bool {
    guard let job = currentJob, translationRecovery?.jobID == job.id,
      translationRecovery?.isComplete == true
    else { return false }
    return ["failed", "cancelled"].contains(job.status)
      && !isImporting && !isSubmitting && !isSaving && !isDeletingJob
  }

  var canDeleteCurrentJob: Bool {
    guard let currentJob else { return false }
    return !currentJob.isRunning && !isSubmitting && !isSaving && !isDeletingJob
  }

  var canStartSavingResult: Bool {
    !isSubmitting && !isSaving && !isDeletingJob
      && currentJob?.status == "done" && currentJob?.output != nil
  }

  var requiresNewResultDestination: Bool {
    currentJob?.status == "done" && resultOriginalDocuments == nil
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
    // Local task controls must remain available while Keychain provider checks await authorization.
    self.capabilities = backend.capabilities()
    let environment = await backend.environment()
    guard !Task.isCancelled else { return }
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
      previewPages = []
      previewError = nil
      isLoadingPreview = false
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
      await refreshTranslationRecovery(jobID: job.id)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func refreshPreview() async {
    guard !isLoadingPreview, !isDeletingJob, let job = currentJob, hasPreviewableResult else {
      return
    }
    await loadPreview(jobID: job.id)
  }

  func deleteCurrentJob(id expectedJobID: String) async {
    guard canDeleteCurrentJob, let job = currentJob, job.id == expectedJobID else { return }
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
    documentImportTask?.cancel()
    jobSubmissionTask?.cancel()
    resultSaveTask?.cancel()
    resultSavePanel?.cancel(nil)
    backend.prepareForTermination()
  }

  func diagnostic(for requirement: RouteRequirement) -> DiagnosticDefinition? {
    if ["deepseek", "openai"].contains(requirement.name) {
      return diagnostics[options.provider]
    }
    return diagnostics[requirement.name]
  }

  func beginPolling(jobID: String) {
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
            } else {
              await refreshTranslationRecovery(jobID: jobID)
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
    resultOriginalDocuments = nil
    previewPages = []
    previewError = nil
    isLoadingPreview = false
    preflightWarnings = []
  }

  private func loadPreview(jobID: String) async {
    guard currentJob?.id == jobID, !isLoadingPreview else { return }
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
      resultOriginalDocuments = nil
      let configuration = try backend.taskConfiguration(jobID: jobID)
      selection = RouteSelection(
        source: configuration.route.source, target: configuration.route.target)
      options = configuration.options
      currentJob = job
      if job.isRunning {
        beginPolling(jobID: job.id)
      } else if job.status == "done" {
        await loadPreview(jobID: job.id)
      } else {
        await refreshTranslationRecovery(jobID: job.id)
        if !Task.isCancelled, currentJob?.id == job.id,
          job.errorCode == "translation_layout_overflow", translationRecovery?.isComplete == true
        {
          rebuildTranslationPDF(outputMode: options.outputMode)
        }
      }
    } catch {
      preferences.removeObject(forKey: lastJobKey)
    }
  }
}
