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
  @Published private(set) var translationRecovery: TranslationRecoverySummary?
  @Published private(set) var translationRecoveryError: String?
  @Published private(set) var isLoadingTranslationRecovery = false
  private var recoveryLoadID = UUID()
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
  @Published var inspectionPage = 1
  private(set) var resultOriginalDocuments: [SelectedDocument]?

  let backend: NativeDocumentEngine
  private var pollingTask: Task<Void, Never>?
  private var retentionCleanupTask: Task<Void, Never>?
  private var documentImportTask: Task<Void, Never>?
  private var jobSubmissionTask: Task<Void, Never>?
  private var resultSaveTask: Task<Void, Never>?
  private var isStarting = false
  private var hasStarted = false
  private let preferences: UserDefaults
  private let jobCreator: JobCreator
  private let resultDestinationPicker: ResultDestinationPicker
  private let resultDownloader: ResultDownloader
  private let resultRevealer: ResultRevealer
  private let documentInspector: DocumentInspector
  private let lastJobKey = "transall.native.lastJobId"

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
    self.resultDestinationPicker = resultDestinationPicker ?? Self.pickResultDestination
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
    guard let job = currentJob, translationRecovery?.jobID == job.id else { return false }
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

  func canChooseFormat(_ format: String) -> Bool {
    guard canChangeRoute else { return false }
    if selection.source == nil || selection.target != nil {
      return NativeCapabilities.routes.contains { $0.source == format && $0.enabled }
    }
    return NativeCapabilities.routes.contains {
      $0.source == selection.source && $0.target == format && $0.enabled
    }
  }

  func chooseFormat(_ format: String, animated: Bool = true) {
    if let routeChangeLock {
      errorMessage = routeChangeLock.errorMessage(reset: false)
      return
    }
    guard canChooseFormat(format) else { return }
    var next = selection
    next.choose(format)
    resetFormatSelection()
    selection = next
  }

  // A slot drag is validated as one operation, so an invalid swap cannot erase a draft.
  func formatSelection(
    dropping format: String, from origin: FormatRouteSlot? = nil, to destination: FormatRouteSlot?
  ) -> RouteSelection? {
    guard canChangeRoute else { return nil }
    var next = selection
    if let origin {
      guard next[origin] == format else { return nil }
      if origin == destination { return next }
      next[origin] = destination.flatMap { next[$0] }
    } else if destination == nil {
      return nil
    }
    if let destination { next[destination] = format }
    guard supportsFormatSelection(next) else { return nil }
    return next
  }

  private func supportsFormatSelection(_ selection: RouteSelection) -> Bool {
    NativeCapabilities.routes.contains {
      $0.enabled && (selection.source == nil || $0.source == selection.source)
        && (selection.target == nil || $0.target == selection.target)
    }
  }

  var formatReversalDisabledReason: String? {
    if let routeChangeLock { return routeChangeLock.helpText }
    if selection.source == nil && selection.target == nil { return "请先选择格式" }
    if selection.source == selection.target { return "源格式与目标格式相同" }
    guard supportsFormatSelection(selection.reversed) else {
      if let source = selection.target, let target = selection.source {
        return "暂不支持 \(NativeFormatOrbit.title(source)) → \(NativeFormatOrbit.title(target))"
      }
      let slot: FormatRouteSlot = selection.source == nil ? .source : .target
      let format = selection.source ?? selection.target ?? ""
      return "\(NativeFormatOrbit.title(format)) 不能用作\(slot.title)"
    }
    return nil
  }

  @discardableResult
  func reverseFormats(expectedSelection: RouteSelection) -> Bool {
    guard selection == expectedSelection, formatReversalDisabledReason == nil else { return false }
    return applyFormatSelection(selection.reversed)
  }

  @discardableResult
  func dropFormat(
    _ format: String, from origin: FormatRouteSlot? = nil, to destination: FormatRouteSlot?
  ) -> Bool {
    guard let next = formatSelection(dropping: format, from: origin, to: destination) else {
      return false
    }
    return applyFormatSelection(next)
  }

  private func applyFormatSelection(_ next: RouteSelection) -> Bool {
    guard next != selection else { return true }
    clearRouteDraft()
    options = JobOptions()
    if let provider = providers.first(where: \.configured) { options.provider = provider.name }
    showAdvanced = false
    selection = next
    return true
  }

  func orbitDockingFeedback(
    for format: String, from origin: FormatRouteSlot?, at point: CGPoint,
    layout: HourglassLayout
  ) -> OrbitDockingTarget? {
    guard canChangeRoute else { return nil }
    // An occupied chamber uses the same compatibility and morph feedback as an empty one.
    // Prefer the actual hit chamber so the neighboring role cannot steal a replacement.
    let candidates = layout.slot(at: point).map { [$0] } ?? FormatRouteSlot.allCases
    return candidates.compactMap { slot -> OrbitDockingTarget? in
      let frame = layout.slotFrame(slot)
      let strength = NativeFormatOrbit.dockingStrength(at: point, to: frame, slot: slot)
      guard strength > 0 else { return nil }
      return OrbitDockingTarget(
        slot: slot, frame: frame, strength: strength,
        compatibility: formatSelection(dropping: format, from: origin, to: slot) == nil
          ? .incompatible : .compatible)
    }.max { $0.strength < $1.strength }
  }

  func orbitPreparedRelease(
    for format: String, from origin: FormatRouteSlot?, docking: OrbitDockingTarget?
  ) -> OrbitReleasePresentation? {
    guard let docking, docking.compatibility == .compatible,
      let old = selection[docking.slot], old != format,
      let next = formatSelection(dropping: format, from: origin, to: docking.slot),
      next.source != old, next.target != old
    else { return nil }
    return .preparation(
      item: OrbitReleasedFormat(format: old, slot: docking.slot),
      strength: docking.strength)
  }

  func orbitDropSelection(
    for format: String, from origin: FormatRouteSlot?, at point: CGPoint,
    layout: HourglassLayout
  ) -> RouteSelection? {
    let slot = layout.slot(at: point)
    // The waist belongs to neither chamber; dropping there must not remove an occupied format.
    guard slot != nil || !layout.frame.contains(point) else { return nil }
    return formatSelection(dropping: format, from: origin, to: slot)
  }

  func orbitPreviewSelection(
    for format: String, from origin: FormatRouteSlot?, docking: OrbitDockingTarget?
  ) -> RouteSelection? {
    guard let docking, docking.compatibility == .compatible, docking.strength > 0 else {
      return nil
    }
    return formatSelection(dropping: format, from: origin, to: docking.slot)
  }

  func orbitRoles(for format: String, selection preview: RouteSelection? = nil) -> OrbitFormatRoles
  {
    let selection = preview ?? self.selection
    var asSource = selection
    asSource.source = format
    var asTarget = selection
    asTarget.target = format
    return OrbitFormatRoles(
      source: supportsFormatSelection(asSource), target: supportsFormatSelection(asTarget))
  }

  func orbitDestinations(for format: String, activeSlot: FormatRouteSlot) -> [FormatRouteSlot] {
    NativeFormatOrbit.candidateSlots(for: selection, activeSlot: activeSlot).filter {
      formatSelection(dropping: format, to: $0) != nil
    }
  }

  func resetFormatSelection(keepingSource: Bool = false) {
    guard canChangeRoute else { return }
    let source = keepingSource ? selection.source : nil
    resetRoute(animated: false)
    selection.source = source
    options = JobOptions()
    if let provider = providers.first(where: \.configured) { options.provider = provider.name }
    showAdvanced = false
  }

  func resetRoute(animated: Bool = true) {
    if let routeChangeLock {
      errorMessage = routeChangeLock.errorMessage(reset: true)
      return
    }
    let changes = { [self] in
      clearRouteDraft()
      selection.clear()
    }
    if animated {
      withAnimation(.easeOut(duration: 0.3), changes)
    } else {
      changes()
    }
  }

  private func clearRouteDraft() {
    pollingTask?.cancel()
    preferences.removeObject(forKey: lastJobKey)
    inspectionPage = 1
    showInputPreview = false
    documents = []
    currentJob = nil
    resultOriginalDocuments = nil
    previewPages = []
    previewError = nil
    isLoadingPreview = false
    preflightWarnings = []
    errorMessage = nil
  }

  func startDocumentImport(_ urls: [URL], appending: Bool = false) {
    guard !urls.isEmpty else {
      errorMessage = "没有选择文件。"
      return
    }
    guard documentImportTask == nil, !isImporting else { return }
    guard canEditTaskDraft else {
      errorMessage = taskDraftLockMessage.map { "\($0)。" } ?? "当前无法修改文件和参数。"
      return
    }
    guard route?.enabled == true else {
      errorMessage = "请先选择源格式和目标格式。"
      return
    }

    isImporting = true
    errorMessage = nil
    documentImportTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isImporting = false
        documentImportTask = nil
      }
      await performDocumentImport(urls, appending: appending)
    }
  }

  func importDocuments(_ urls: [URL], appending: Bool = false) async {
    startDocumentImport(urls, appending: appending)
    guard let documentImportTask else { return }
    await documentImportTask.value
  }

  func requestDocumentImportCancellation() {
    documentImportTask?.cancel()
  }

  func cancelDocumentImport() async {
    guard let documentImportTask else { return }
    documentImportTask.cancel()
    await documentImportTask.value
  }

  private func performDocumentImport(_ urls: [URL], appending: Bool) async {
    guard !Task.isCancelled else { return }

    var seenURLs = Set(
      (appending ? documents : []).map { $0.url.standardizedFileURL })
    let uniqueURLs = urls.filter {
      seenURLs.insert($0.standardizedFileURL).inserted
    }
    guard seenURLs.count <= NativeCapabilities.maximumInputFileCount else {
      errorMessage =
        "每批最多选择 \(NativeCapabilities.maximumInputFileCount) 个文件，请分批处理。"
      return
    }

    let imported: [SelectedDocument]
    do {
      imported = try await documentInspector(uniqueURLs)
      try Task.checkCancellation()
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
      return
    }

    var combined = appending ? documents : []
    var existing = Set(combined.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
    combined.append(
      contentsOf: imported.filter {
        existing.insert($0.url.standardizedFileURL.resolvingSymlinksInPath()).inserted
      })
    guard combined.count <= NativeCapabilities.maximumInputFileCount else {
      errorMessage =
        "每批最多选择 \(NativeCapabilities.maximumInputFileCount) 个文件，请分批处理。"
      return
    }

    if let route {
      let extensions = Set(
        route.accept.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
            .lowercased()
        })
      if let invalid = combined.first(where: {
        !extensions.contains($0.url.pathExtension.lowercased())
      }) {
        errorMessage = "\(invalid.name)：当前任务接受 \(route.accept)。"
        return
      }
    }

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
    guard !Task.isCancelled else { return }
    if currentJob?.isFinished == true {
      currentJob = nil
      resultOriginalDocuments = nil
      previewPages = []
      previewError = nil
      isLoadingPreview = false
      preferences.removeObject(forKey: lastJobKey)
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
    guard !isImporting, canEditTaskDraft else { return }
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

  func refreshTranslationRecovery(jobID: String) async {
    guard let job = currentJob, job.id == jobID, job.kind == "pdf_translate",
      ["failed", "cancelled"].contains(job.status), !isDeletingJob, !isSubmitting
    else { return }
    let requestID = UUID()
    recoveryLoadID = requestID
    isLoadingTranslationRecovery = true
    translationRecovery = nil
    translationRecoveryError = nil
    defer {
      if recoveryLoadID == requestID { isLoadingTranslationRecovery = false }
    }
    do {
      let recovery = try await backend.translationRecovery(jobID: jobID)
      try Task.checkCancellation()
      guard recoveryLoadID == requestID, currentJob?.id == jobID,
        currentJob?.status == job.status, !isDeletingJob, !isSubmitting
      else { return }
      translationRecovery = TranslationRecoverySummary(
        jobID: jobID, regionCount: recovery.regions.count,
        issueCount: recovery.overflowRegionIDs.count,
        issuePages: Array(Set(recovery.issues.map { $0.pageIndex + 1 })).sorted())
    } catch is CancellationError {
      return
    } catch {
      guard recoveryLoadID == requestID, currentJob?.id == jobID,
        currentJob?.status == job.status
      else { return }
      if job.errorCode == "translation_layout_overflow" {
        translationRecoveryError = "无法复用已保存的译文：\(error.localizedDescription)"
      }
    }
  }

  func recoverTranslationAsPlainPDF(jobID: String) {
    guard canRecoverTranslation, currentJob?.id == jobID else { return }
    do {
      let queued = try backend.recoverTranslationAsPlainPDF(jobID: jobID)
      pollingTask?.cancel()
      currentJob = queued
      previewPages = []
      previewError = nil
      isLoadingPreview = false
      errorMessage = nil
      options.outputMode = "translated"
      preferences.set(jobID, forKey: lastJobKey)
      beginPolling(jobID: jobID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func clearTranslationRecovery() {
    recoveryLoadID = UUID()
    translationRecovery = nil
    translationRecoveryError = nil
    isLoadingTranslationRecovery = false
  }

  func startSavingResult() {
    guard resultSaveTask == nil, canStartSavingResult,
      let job = currentJob, job.status == "done", let output = job.output
    else { return }
    let originalDocuments = resultOriginalDocuments
    let allowReplacingExistingDestination = originalDocuments != nil
    guard let destination = resultDestinationPicker(output) else { return }

    do {
      try ResultSavePolicy.validate(
        destination: destination, originalDocuments: originalDocuments)
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
        try await resultDownloader(
          job.id, destination, allowReplacingExistingDestination)
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
