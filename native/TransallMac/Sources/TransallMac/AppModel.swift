import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
  @Published var capabilities: CapabilitiesResponse?
  @Published var diagnostics: [String: DiagnosticDefinition] = [:]
  @Published var providers: [ProviderDefinition] = []
  @Published var selection = RouteSelection()
  @Published var documents: [SelectedDocument] = []
  @Published var options = JobOptions()
  @Published var currentJob: JobResponse?
  @Published var previewPages: [PreviewPage] = []
  @Published var preflightWarnings: [PreflightIssue] = []
  @Published var errorMessage: String?
  @Published var isSubmitting = false
  @Published var isSaving = false
  @Published var showAdvanced = false

  let backend = NativeDocumentEngine()
  private var pollingTask: Task<Void, Never>?
  private let lastJobKey = "transall.native.lastJobId"

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
      && !isSubmitting
      && currentJob?.isRunning != true
  }

  var routeTitle: String {
    route?.title ?? "选择源格式和目标格式"
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
    await backend.start()
    guard case .running = backend.state else { return }
    await reloadEnvironment()
    await restoreLastJob()
  }

  func reloadEnvironment() async {
    let capabilities = backend.capabilities()
    let diagnostics = backend.diagnostics()
    let providers = backend.providers()
    self.capabilities = capabilities
    self.diagnostics = Dictionary(
      uniqueKeysWithValues: diagnostics.dependencies.map { ($0.name, $0) })
    self.providers = providers.providers
    if !providers.providers.contains(where: { $0.name == options.provider && $0.configured }),
      let configured = providers.providers.first(where: \.configured)
    {
      options.provider = configured.name
    }
    errorMessage = nil
  }

  func chooseFormat(_ format: String, animated: Bool = true) {
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
    guard currentJob?.isRunning != true else {
      errorMessage = "任务运行中，请先取消任务再重选路径。"
      return
    }
    pollingTask?.cancel()
    let changes = { [self] in
      selection.clear()
      documents = []
      currentJob = nil
      previewPages = []
      preflightWarnings = []
      errorMessage = nil
    }
    if animated {
      withAnimation(.easeOut(duration: 0.3), changes)
    } else {
      changes()
    }
  }

  func importDocuments(_ urls: [URL], appending: Bool = false) {
    let imported = urls.compactMap { url -> SelectedDocument? in
      let accessing = url.startAccessingSecurityScopedResource()
      defer {
        if accessing { url.stopAccessingSecurityScopedResource() }
      }
      guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
      return SelectedDocument(url: url, size: Int64(size))
    }
    guard !imported.isEmpty else {
      errorMessage = "无法读取所选文件。"
      return
    }

    var combined = appending ? documents : []
    var existing = Set(combined.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
    combined.append(
      contentsOf: imported.filter {
        existing.insert($0.url.standardizedFileURL.resolvingSymlinksInPath()).inserted
      })

    let total = combined.reduce(Int64.zero) { $0 + $1.size }
    if let limit = capabilities?.limits.maxUploadBytes, total > Int64(limit) {
      errorMessage = "所选文件超过 \(capabilities?.limits.maxUploadMB ?? 0) MB 限制。"
      return
    }
    documents = combined
    errorMessage = nil
  }

  func removeDocument(_ document: SelectedDocument) {
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

  func runJob() async {
    guard let route, route.enabled, !documents.isEmpty else { return }
    isSubmitting = true
    errorMessage = nil
    previewPages = []
    preflightWarnings = []
    do {
      let preflight = backend.preflight(route: route, files: documents, options: options)
      preflightWarnings = preflight.warnings
      guard preflight.ok else {
        errorMessage = preflight.blockingIssues
          .map { [$0.message, $0.hint].compactMap { $0 }.joined(separator: "：") }
          .joined(separator: "\n")
        isSubmitting = false
        return
      }

      let job = try await backend.createJob(route: route, files: documents, options: options)
      currentJob = job
      UserDefaults.standard.set(job.id, forKey: lastJobKey)
      isSubmitting = false
      beginPolling(jobID: job.id)
    } catch {
      isSubmitting = false
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

  func saveResult() async {
    guard let job = currentJob, job.status == "done", let output = job.output else { return }
    let panel = NSSavePanel()
    panel.nameFieldStringValue = output
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let destination = panel.url else { return }

    isSaving = true
    defer { isSaving = false }
    do {
      try await backend.download(jobID: job.id, to: destination)
      NSWorkspace.shared.activateFileViewerSelecting([destination])
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func refreshPreview() async {
    guard let job = currentJob else { return }
    await loadPreview(jobID: job.id)
  }

  func deleteCurrentJob() async {
    guard let job = currentJob, !job.isRunning else { return }
    do {
      try backend.deleteJob(id: job.id)
      UserDefaults.standard.removeObject(forKey: lastJobKey)
      currentJob = nil
      previewPages = []
      preflightWarnings = []
    } catch {
      errorMessage = error.localizedDescription
    }
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

  private func loadPreview(jobID: String) async {
    do {
      previewPages = try await backend.previewPages(jobID: jobID).pages
    } catch {
      previewPages = []
    }
  }

  private func restoreLastJob() async {
    guard let jobID = UserDefaults.standard.string(forKey: lastJobKey) else { return }
    do {
      let job = try backend.job(id: jobID)
      currentJob = job
      if job.isRunning {
        beginPolling(jobID: job.id)
      } else if job.status == "done" {
        await loadPreview(jobID: job.id)
      }
    } catch {
      UserDefaults.standard.removeObject(forKey: lastJobKey)
    }
  }
}
