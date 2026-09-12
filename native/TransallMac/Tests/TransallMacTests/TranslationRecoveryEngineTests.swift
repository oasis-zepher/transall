import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import TransallMac

@Suite(.serialized)
struct TranslationRecoveryEngineTests {
  @Test @MainActor
  func failedLayoutInspectionShowsSubmittedOriginalAndExactProblemRegion() async throws {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let engine = fixture.engine()
    defer { engine.prepareForTermination() }
    await engine.start()
    let submittedBytes = try Data(contentsOf: fixture.source)
    let job = try await fixture.submit(to: engine)
    let failed = try await finishedJob(job.id, in: engine)
    #expect(failed.status == "failed")
    #expect(failed.errorCode == "translation_layout_overflow")
    #expect(failed.errorHint?.contains("无需再次调用翻译服务") == true)
    #expect(failed.output == nil)
    try Data("Original changed after submission".utf8).write(to: fixture.source)

    let recovery = try await engine.translationRecovery(jobID: job.id)
    #expect(recovery.issues.count == 1)
    #expect(recovery.issues.first?.id == RecoveryEngineFixture.problemRegion.id)
    #expect(recovery.issues.first?.pageIndex == 1)
    #expect(recovery.issues.first?.bounds == RecoveryEngineFixture.problemRegion.bounds)
    #expect(recovery.issues.first?.translatedText == RecoveryEngineFixture.secondTranslation)

    let snapshot = try await engine.inspectionSnapshot(jobID: job.id)
    defer { try? FileManager.default.removeItem(at: snapshot.directory) }
    #expect(snapshot.result == nil)
    let original = try #require(snapshot.original)
    #expect(try Data(contentsOf: original) == submittedBytes)
    #expect(PDFDocument(url: original)?.pageCount == 2)
    #expect(snapshot.issues.count == 1)
    #expect(snapshot.issues.first?.pageIndex == 1)
    #expect(snapshot.issues.first?.bounds == RecoveryEngineFixture.problemRegion.bounds)
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == [.deepseek])
  }

  @Test @MainActor
  func recoveryReusesEveryTranslationWithoutAnotherProcessorOrCredentialRead() async throws {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let engine = fixture.engine()
    defer { engine.prepareForTermination() }
    await engine.start()
    let submitted = try await fixture.submit(to: engine)
    _ = try await finishedJob(submitted.id, in: engine)
    try Data("The external source is no longer available".utf8).write(to: fixture.source)

    let queued = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
    #expect(queued.id == submitted.id)
    #expect(queued.status == "queued")
    #expect(queued.errorCode == nil)
    #expect(queued.error == nil)
    let completed = try await finishedJob(submitted.id, in: engine)
    #expect(completed.status == "done")
    #expect(completed.errorCode == nil)
    #expect(completed.progress == 100)
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == [.deepseek])

    let destination = fixture.directory.appendingPathComponent("saved.pdf")
    try await engine.download(jobID: submitted.id, to: destination)
    let text = try #require(PDFDocument(url: destination)?.string)
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(text.contains(RecoveryEngineFixture.firstTranslation))
    #expect(text.contains(RecoveryEngineFixture.secondTranslation))
    #expect(!text.contains("SOURCE FIRST PAGE"))

    let jobDirectory = fixture.jobDirectory(submitted.id)
    let metadata = try #require(
      JSONSerialization.jsonObject(
        with: Data(contentsOf: jobDirectory.appendingPathComponent("metadata.json")))
        as? [String: Any])
    let options = try #require(metadata["options"] as? [String: Any])
    #expect(options["outputMode"] as? String == "translated")
    #expect(
      FileManager.default.fileExists(
        atPath: jobDirectory.appendingPathComponent("completion.json").path))

    let output = jobDirectory.appendingPathComponent(try #require(completed.output))
    try RecoveryEngineFixture.writePDF(to: output, prefix: "SUBSTITUTED")
    #expect(PDFDocument(url: output)?.pageCount == 2)
    let rejectedDestination = fixture.directory.appendingPathComponent("rejected.pdf")
    do {
      try await engine.download(jobID: submitted.id, to: rejectedDestination)
      Issue.record("Recovered results must retain completion-receipt verification")
    } catch is NativeDocumentError {
      #expect(!FileManager.default.fileExists(atPath: rejectedDestination.path))
    }
  }

  @Test @MainActor
  func persistedTranslationCanRecoverAfterRestartAndCompletedResultSurvivesNextRestart()
    async throws
  {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let first = fixture.engine()
    await first.start()
    let submitted = try await fixture.submit(to: first)
    let failed = try await finishedJob(submitted.id, in: first)
    #expect(failed.errorCode == "translation_layout_overflow")
    first.prepareForTermination()
    try FileManager.default.removeItem(at: fixture.source)

    let restarted = fixture.engine()
    defer { restarted.prepareForTermination() }
    await restarted.start()
    #expect(try restarted.job(id: submitted.id).status == "failed")
    #expect(try await restarted.translationRecovery(jobID: submitted.id).issues.count == 1)
    _ = try restarted.recoverTranslationAsPlainPDF(jobID: submitted.id)
    let completed = try await finishedJob(submitted.id, in: restarted)
    #expect(completed.status == "done")
    restarted.prepareForTermination()

    let last = fixture.engine()
    defer { last.prepareForTermination() }
    await last.start()
    let restored = try last.job(id: submitted.id)
    #expect(restored.status == "done")
    #expect(restored.output == completed.output)
    let destination = fixture.directory.appendingPathComponent("restored.pdf")
    try await last.download(jobID: submitted.id, to: destination)
    #expect(PDFDocument(url: destination)?.string?.contains("Translated first block") == true)
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == [.deepseek])
  }

  @Test(arguments: RecoveryTampering.allCases) @MainActor
  func corruptedOrSubstitutedRecoveryDataCannotProduceASuccess(tampering: RecoveryTampering)
    async throws
  {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let engine = fixture.engine()
    defer { engine.prepareForTermination() }
    await engine.start()
    let submitted = try await fixture.submit(to: engine)
    _ = try await finishedJob(submitted.id, in: engine)
    let jobDirectory = fixture.jobDirectory(submitted.id)
    let inputDirectory = jobDirectory.appendingPathComponent("Input", isDirectory: true)
    let input = try #require(
      FileManager.default.contentsOfDirectory(
        at: inputDirectory, includingPropertiesForKeys: nil
      ).first)
    let cache = jobDirectory.appendingPathComponent(TranslationRecoveryStore.filename)
    switch tampering {
    case .alteredCachedTranslation:
      var envelope = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
      var document = try #require(envelope["document"] as? [String: Any])
      var translations = try #require(document["translations"] as? [String: String])
      translations[RecoveryEngineFixture.problemRegion.id] = "A silently substituted translation."
      document["translations"] = translations
      envelope["document"] = document
      try JSONSerialization.data(withJSONObject: envelope).write(to: cache)
    case .changedSubmittedInput:
      try RecoveryEngineFixture.writePDF(to: input, prefix: "SUBSTITUTED")
    case .linkedCache:
      let external = fixture.directory.appendingPathComponent("external-cache.json")
      try FileManager.default.moveItem(at: cache, to: external)
      try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: external)
    case .linkedSubmittedInput:
      try FileManager.default.removeItem(at: input)
      try FileManager.default.createSymbolicLink(at: input, withDestinationURL: fixture.source)
    }

    do {
      _ = try await engine.translationRecovery(jobID: submitted.id)
      Issue.record("Recovery inspection must reject corrupted or substituted cached inputs")
    } catch is NativeDocumentError {}
    do {
      _ = try await engine.inspectionSnapshot(jobID: submitted.id)
      Issue.record("Issue inspection must validate its cached document and submitted original")
    } catch is NativeDocumentError {}
    do {
      _ = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
      _ = try await finishedJob(submitted.id, in: engine)
    } catch is NativeDocumentError {}

    let rejected = try engine.job(id: submitted.id)
    #expect(rejected.status == "failed")
    #expect(rejected.output == nil)
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == [.deepseek])
    let names = try FileManager.default.contentsOfDirectory(atPath: jobDirectory.path)
    #expect(!names.contains("completion.json"))
    #expect(!names.contains { $0.hasPrefix("Inspection-") })
    #expect(!names.contains { $0.lowercased().hasSuffix(".pdf") })
  }

  @Test @MainActor
  func recoveryRejectsActiveAndRepeatedRequests() async throws {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let gate = RecoveryProcessingGate()
    defer { Task { await gate.release() } }
    let engine = fixture.engine(gate: gate)
    defer { engine.prepareForTermination() }
    await engine.start()
    let submitted = try await fixture.submit(to: engine)
    await gate.waitUntilEntered()
    do {
      _ = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
      Issue.record("An active translation cannot be replaced by a recovery export")
    } catch is NativeDocumentError {}
    await gate.release()
    _ = try await finishedJob(submitted.id, in: engine)

    _ = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
    do {
      _ = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
      Issue.record("A queued recovery must not start a second export")
    } catch is NativeDocumentError {}
    let completed = try await finishedJob(submitted.id, in: engine)
    #expect(completed.status == "done")
    do {
      _ = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
      Issue.record("A completed recovery must not overwrite its verified output")
    } catch is NativeDocumentError {}
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == [.deepseek])
  }

  @Test @MainActor
  func cancelledRecoveryCanRetryAndDiscardWaitsBeforeRemovingAllTaskData() async throws {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let engine = fixture.engine()
    defer { engine.prepareForTermination() }
    await engine.start()
    let submitted = try await fixture.submit(to: engine)
    _ = try await finishedJob(submitted.id, in: engine)
    _ = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
    let cancelled = try engine.cancelJob(id: submitted.id)
    #expect(cancelled.status == "cancelled")
    #expect(cancelled.output == nil)

    // Cancellation returns before its worker has stopped. Wait for cache access to become available.
    var recoveryReady = false
    for _ in 0..<500 where !recoveryReady {
      do {
        _ = try await engine.translationRecovery(jobID: submitted.id)
        recoveryReady = true
      } catch is NativeDocumentError {
        try await Task.sleep(for: .milliseconds(10))
      }
    }
    #expect(recoveryReady)
    let jobDirectory = fixture.jobDirectory(submitted.id)
    #expect(
      !FileManager.default.fileExists(
        atPath: jobDirectory.appendingPathComponent("completion.json").path))
    let names = try FileManager.default.contentsOfDirectory(atPath: jobDirectory.path)
    #expect(!names.contains { $0.lowercased().hasSuffix(".pdf") || $0.hasPrefix("Recovery-") })
    _ = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
    do {
      try await engine.deleteJob(id: submitted.id)
      Issue.record("A queued recovery must be cancelled before its inputs can be removed")
    } catch is NativeDocumentError {}
    try await engine.discardJob(id: submitted.id)
    #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == [.deepseek])
    do {
      _ = try engine.recoverTranslationAsPlainPDF(jobID: submitted.id)
      Issue.record("A deleted task cannot regenerate its recovery directory")
    } catch {}
    #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
  }

  @Test @MainActor
  func interruptedLocalRecoveryStillUsesItsCacheAfterRestart() async throws {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let first = fixture.engine()
    defer { first.prepareForTermination() }
    await first.start()
    let submitted = try await fixture.submit(to: first)
    _ = try await finishedJob(submitted.id, in: first)
    _ = try first.recoverTranslationAsPlainPDF(jobID: submitted.id)

    // Capture the persisted queued recovery before its MainActor startup callback can run.
    // A separate directory models the next process without racing the old process's cancellation.
    let restartedStorage = fixture.directory.appendingPathComponent(
      "RestartedData", isDirectory: true)
    let restartedJobs = restartedStorage.appendingPathComponent("Jobs", isDirectory: true)
    try FileManager.default.createDirectory(at: restartedJobs, withIntermediateDirectories: true)
    try FileManager.default.copyItem(
      at: fixture.jobDirectory(submitted.id),
      to: restartedJobs.appendingPathComponent(submitted.id, isDirectory: true))
    first.prepareForTermination()

    let restarted = fixture.engine(storageOverride: restartedStorage)
    defer { restarted.prepareForTermination() }
    await restarted.start()
    let interrupted = try restarted.job(id: submitted.id)
    #expect(interrupted.status == "failed")
    #expect(interrupted.errorCode == "task_interrupted")
    #expect(try await restarted.translationRecovery(jobID: submitted.id).issues.count == 1)
    _ = try restarted.recoverTranslationAsPlainPDF(jobID: submitted.id)
    let recovered = try await finishedJob(submitted.id, in: restarted)
    #expect(recovered.status == "done")
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == [.deepseek])
  }

  @Test @MainActor
  func modelClearsRecoveryWhenChangingJobsAndIgnoresAnOldJobButton() async throws {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let engine = fixture.engine()
    await engine.start()
    let first = try await fixture.submit(to: engine)
    let firstFailure = try await finishedJob(first.id, in: engine)
    let second = try await fixture.submit(to: engine)
    let secondFailure = try await finishedJob(second.id, in: engine)
    let suiteName = "transall-recovery-model-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let model = AppModel(backend: engine, preferences: preferences)
    defer { model.prepareForTermination() }
    model.currentJob = firstFailure
    await model.refreshTranslationRecovery(jobID: first.id)
    #expect(
      model.translationRecovery
        == TranslationRecoverySummary(
          jobID: first.id, regionCount: 2, issueCount: 1, issuePages: [2]))
    #expect(model.canRecoverTranslation)

    model.currentJob = secondFailure
    #expect(model.translationRecovery == nil)
    #expect(!model.canRecoverTranslation)
    await model.refreshTranslationRecovery(jobID: second.id)
    #expect(model.translationRecovery?.jobID == second.id)
    #expect(model.canRecoverTranslation)
    model.recoverTranslationAsPlainPDF(jobID: first.id)
    #expect(model.currentJob?.id == second.id)
    #expect(model.currentJob?.status == "failed")
    #expect(try engine.job(id: first.id).status == "failed")
    #expect(try engine.job(id: second.id).status == "failed")

    model.currentJob = nil
    await model.refreshTranslationRecovery(jobID: second.id)
    #expect(model.translationRecovery == nil)
    #expect(model.translationRecoveryError == nil)
    #expect(!model.canRecoverTranslation)
  }

  @Test @MainActor
  func modelRecoveryPreservesTheSubmittedOriginalProtection() async throws {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let suiteName = "transall-recovery-original-policy-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let engine = fixture.engine()
    var downloadCalls = 0
    let model = AppModel(
      backend: engine, preferences: preferences,
      resultDestinationPicker: { _ in fixture.source },
      resultDownloader: { _, _, _ in downloadCalls += 1 }, resultRevealer: { _ in })
    defer { model.prepareForTermination() }
    await engine.start()
    model.capabilities = NativeCapabilities.response
    model.selection = RouteSelection(source: "pdf", target: "translated_pdf")
    model.options.outputMode = "preserve_layout"
    let sourceBytes = try Data(contentsOf: fixture.source)
    let submittedDocument = SelectedDocument(url: fixture.source, size: Int64(sourceBytes.count))
    model.documents = [submittedDocument]
    await model.runJob()
    let jobID = try #require(model.currentJob?.id)
    try await waitForModel(model) { $0.canRecoverTranslation }
    #expect(model.currentJob?.errorCode == "translation_layout_overflow")
    #expect(model.resultOriginalDocuments == [submittedDocument])
    let readsBeforeRecovery = fixture.calls.credentialReads
    model.documents = []

    model.recoverTranslationAsPlainPDF(jobID: jobID)
    #expect(model.currentJob?.id == jobID)
    #expect(model.translationRecovery == nil)
    #expect(!model.canRecoverTranslation)
    #expect(model.options.outputMode == "translated")
    #expect(model.resultOriginalDocuments == [submittedDocument])
    try await waitForModel(model) { $0.currentJob?.status == "done" }
    #expect(!model.requiresNewResultDestination)
    model.startSavingResult()
    #expect(downloadCalls == 0)
    #expect(!model.isSaving)
    #expect(model.errorMessage != nil)
    #expect(try Data(contentsOf: fixture.source) == sourceBytes)
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == readsBeforeRecovery)
  }

  @Test @MainActor
  func restartedModelRestoresRecoverySummaryAndRequiresANewSaveDestination() async throws {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let first = fixture.engine()
    await first.start()
    let submitted = try await fixture.submit(to: first)
    _ = try await finishedJob(submitted.id, in: first)
    first.prepareForTermination()
    let suiteName = "transall-recovery-restored-model-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    preferences.set(submitted.id, forKey: "transall.native.lastJobId")
    var downloadCalls = 0
    let model = AppModel(
      backend: fixture.engine(), preferences: preferences,
      resultDestinationPicker: { _ in fixture.source },
      resultDownloader: { _, _, _ in downloadCalls += 1 }, resultRevealer: { _ in })
    defer { model.prepareForTermination() }
    await model.start()
    #expect(model.currentJob?.id == submitted.id)
    #expect(model.currentJob?.status == "failed")
    #expect(model.translationRecovery?.issuePages == [2])
    #expect(model.canRecoverTranslation)
    #expect(model.resultOriginalDocuments == nil)
    let readsBeforeRecovery = fixture.calls.credentialReads

    model.recoverTranslationAsPlainPDF(jobID: submitted.id)
    try await waitForModel(model) { $0.currentJob?.status == "done" }
    #expect(model.resultOriginalDocuments == nil)
    #expect(model.requiresNewResultDestination)
    model.startSavingResult()
    #expect(downloadCalls == 0)
    #expect(!model.isSaving)
    #expect(model.errorMessage?.contains("不能替换已有文件") == true)
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == readsBeforeRecovery)
  }

  @Test(arguments: [false, true]) @MainActor
  func cancelledRecoveryLoadingWaitsForItsWorkerAndFollowsTheCurrentJob(switchAway: Bool)
    async throws
  {
    let fixture = try RecoveryEngineFixture()
    defer { fixture.remove() }
    let gate = RecoveryProcessingGate()
    defer { Task { await gate.release() } }
    let engine = fixture.engine(gate: gate, pauseAfterSaving: true)
    let suiteName = "transall-cancelled-recovery-model-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let model = AppModel(backend: engine, preferences: preferences)
    defer { model.prepareForTermination() }
    await engine.start()
    model.capabilities = NativeCapabilities.response
    model.selection = RouteSelection(source: "pdf", target: "translated_pdf")
    model.options.outputMode = "preserve_layout"
    model.documents = [
      SelectedDocument(url: fixture.source, size: Int64(try Data(contentsOf: fixture.source).count))
    ]
    await model.runJob()
    await gate.waitUntilEntered()
    let jobID = try #require(model.currentJob?.id)
    let cancellation = Task { await model.cancelJob() }
    try await waitForModel(model) { $0.currentJob?.status == "cancelled" }
    #expect(!model.canRecoverTranslation)
    #expect(model.isLoadingTranslationRecovery)
    if switchAway { model.resetRoute(animated: false) }
    await gate.release()
    await cancellation.value
    if switchAway {
      #expect(model.currentJob == nil)
      #expect(model.translationRecovery == nil)
      #expect(model.translationRecoveryError == nil)
      #expect(!model.isLoadingTranslationRecovery)
      #expect(!model.canRecoverTranslation)
      return
    }
    #expect(model.currentJob?.status == "cancelled")
    #expect(model.canRecoverTranslation)
    #expect(model.translationRecovery?.jobID == jobID)
    #expect(model.translationRecovery?.issuePages == [2])
    #expect(model.translationRecoveryError == nil)
    let readsBeforeRecovery = fixture.calls.credentialReads
    model.recoverTranslationAsPlainPDF(jobID: jobID)
    try await waitForModel(model) { $0.currentJob?.status == "done" }
    #expect(fixture.calls.processorCount == 1)
    #expect(fixture.calls.credentialReads == readsBeforeRecovery)
  }

  @MainActor
  private func waitForModel(_ model: AppModel, until predicate: (AppModel) -> Bool) async throws {
    for _ in 0..<250 where !predicate(model) {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(
      predicate(model), "The recovery model did not reach its expected state within five seconds")
  }

  @MainActor
  private func finishedJob(_ id: String, in engine: NativeDocumentEngine) async throws
    -> JobResponse
  {
    var job = try engine.job(id: id)
    for _ in 0..<500 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try engine.job(id: id)
    }
    #expect(job.isFinished, "The local recovery fixture did not finish within five seconds")
    return job
  }
}

enum RecoveryTampering: CaseIterable, Sendable {
  case alteredCachedTranslation, changedSubmittedInput, linkedCache, linkedSubmittedInput
}

private struct RecoveryEngineFixture {
  static let firstTranslation = "Translated first block is retained in full."
  static let secondTranslation = "Translated second page block also remains complete."
  static let problemRegion = PDFTranslationRegion(
    id: "page-2-region", pageIndex: 1, kind: .nativeText,
    bounds: CGRect(x: 30, y: 220, width: 60, height: 12),
    sourceText: "SOURCE SECOND PAGE", preferredFontSize: 14)

  let directory: URL
  let source: URL
  let storage: URL
  let calls = RecoveryCallRecorder()

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "transall-recovery-engine-\(UUID().uuidString)", isDirectory: true)
    source = directory.appendingPathComponent("source.pdf")
    storage = directory.appendingPathComponent("Data", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Self.writePDF(to: source)
  }

  @MainActor
  func engine(
    gate: RecoveryProcessingGate? = nil, pauseAfterSaving: Bool = false,
    storageOverride: URL? = nil
  )
    -> NativeDocumentEngine
  {
    NativeDocumentEngine(
      dataDirectoryOverride: storageOverride ?? storage, credentialStore: calls,
      jobProcessor: { [calls] _, inputs, options, outputURL, _ in
        calls.recordProcessorCall()
        if !pauseAfterSaving { await gate?.pause() }
        let input = try #require(inputs.first)
        let first = PDFTranslationRegion(
          id: "page-1-region", pageIndex: 0, kind: .nativeText,
          bounds: CGRect(x: 30, y: 200, width: 300, height: 40),
          sourceText: "SOURCE FIRST PAGE", preferredFontSize: 14)
        let document = try TranslationRecoveryStore.create(
          inputURL: input, options: options, pageCount: 2,
          regions: [first, Self.problemRegion],
          translations: [
            first.id: Self.firstTranslation, Self.problemRegion.id: Self.secondTranslation,
          ],
          overflowRegionIDs: [Self.problemRegion.id])
        try TranslationRecoveryStore.save(document, in: outputURL.deletingLastPathComponent())
        if pauseAfterSaving { await gate?.pause() }
        throw NativeDocumentError.layoutOverflow(1)
      })
  }

  @MainActor
  func submit(to engine: NativeDocumentEngine) async throws -> JobResponse {
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    var options = JobOptions()
    options.outputMode = "preserve_layout"
    return try await engine.createJob(
      route: route,
      files: [SelectedDocument(url: source, size: Int64(try Data(contentsOf: source).count))],
      options: options)
  }

  func jobDirectory(_ id: String) -> URL {
    storage.appendingPathComponent("Jobs/\(id)", isDirectory: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }

  static func writePDF(to url: URL, prefix: String = "SOURCE") throws {
    var box = CGRect(x: 0, y: 0, width: 400, height: 300)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    for ordinal in ["FIRST", "SECOND"] {
      context.beginPDFPage(nil)
      context.textPosition = CGPoint(x: 30, y: 220)
      CTLineDraw(
        CTLineCreateWithAttributedString(
          NSAttributedString(
            string: "\(prefix) \(ordinal) PAGE",
            attributes: [.font: NSFont.systemFont(ofSize: 14)])), context)
      context.endPDFPage()
    }
    context.closePDF()
  }
}

private actor RecoveryProcessingGate {
  private var entered = false
  private var released = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

  func pause() async {
    entered = true
    for waiter in entryWaiters { waiter.resume() }
    entryWaiters.removeAll()
    if !released {
      await withCheckedContinuation { releaseWaiters.append($0) }
    }
  }

  func waitUntilEntered() async {
    if !entered {
      await withCheckedContinuation { entryWaiters.append($0) }
    }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }
}

private final class RecoveryCallRecorder: ProviderCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var reads: [ProviderCredential] = []
  private var processingCalls = 0

  var credentialReads: [ProviderCredential] { lock.withLock { reads } }
  var processorCount: Int { lock.withLock { processingCalls } }

  func value(for credential: ProviderCredential) throws -> String {
    lock.withLock { reads.append(credential) }
    return "local-test-credential"
  }

  func setValue(_ value: String, for credential: ProviderCredential) throws {}

  func recordProcessorCall() {
    lock.withLock { processingCalls += 1 }
  }
}
