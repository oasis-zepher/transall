import AppKit
import Combine
import CoreText
import PDFKit
import SwiftUI
import Testing

@testable import TransallMac

@Suite(.serialized)
struct WorkbenchTests {
  @Test
  func filePickerAcceptsPDFBeforeSavedRouteIsRestored() {
    #expect(WorkbenchTask.contentTypes(source: nil).contains(.pdf))
    #expect(WorkbenchTask.contentTypes(source: "pdf") == [.pdf])
  }

  @Test
  func taskCatalogCoversEveryNativeRouteExactlyOnce() {
    let selections = WorkbenchTask.allCases.flatMap { task in
      task.sources.map { task.selection(source: $0) }
    }
    let pairs = selections.map { "\($0.source ?? ""):\($0.target ?? "")" }
    let expected = NativeCapabilities.routes.map { "\($0.source):\($0.target)" }
    #expect(pairs.count == Set(pairs).count)
    #expect(Set(pairs) == Set(expected))
    for selection in selections {
      #expect(WorkbenchTask.matching(selection) != nil)
      #expect(!WorkbenchTask.contentTypes(source: selection.source).isEmpty)
    }
    #expect(WorkbenchTask.createPDF.selection().source == "image")
    #expect(WorkbenchTask.recognizeText.selection().source == "pdf")
    #expect(WorkbenchTask.createPDF.selection(source: "unsupported").source == "image")
  }

  @Test @MainActor
  func selectingTaskClearsDraftAndRejectsLockedChanges() {
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    model.selectTask(.translatePDF)
    model.documents = [SelectedDocument(url: URL(fileURLWithPath: "/tmp/input.pdf"), size: 1)]
    model.options.glossary = "draft glossary"
    model.previewPages = [PreviewPage(page: 1, url: "stale.png")]
    model.selectTask(.createPDF, source: "md")
    #expect(model.route?.source == "md")
    #expect(model.route?.target == "pdf")
    #expect(model.documents.isEmpty)
    #expect(model.selectedDocumentID == nil)
    #expect(model.previewPages.isEmpty)
    #expect(model.options.glossary.isEmpty)
    model.isSubmitting = true
    model.selectTask(.editPDF)
    #expect(model.selectedTask == .createPDF)
    model.isSubmitting = false
    model.isDeletingJob = true
    model.selectTask(.editPDF)
    #expect(model.selectedTask == .createPDF)
    #expect(!model.canSelectDocuments)
  }

  @Test @MainActor
  func incompatibleDropIsAtomicAndFileSelectionFollowsRemoval() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.pdf")
    let second = directory.appendingPathComponent("second.pdf")
    let invalid = directory.appendingPathComponent("image.png")
    for url in [first, second, invalid] { try Data("test".utf8).write(to: url) }
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    model.selectTask(.editPDF)
    await model.importDocuments([first])
    await model.importDocuments([second, invalid], appending: true)
    #expect(model.documents.map(\.url) == [first])
    #expect(model.errorMessage?.contains("image.png") == true)
    await model.importDocuments([second], appending: true)
    #expect(model.selectedDocumentID == first)
    model.removeDocument(model.documents[0])
    #expect(model.selectedDocumentID == second)
  }

  @Test(arguments: [true, false]) @MainActor
  func importingAfterCompletionPreservesPreviewAndExport(appending: Bool) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("completed.pdf")
    let second = directory.appendingPathComponent("next.pdf")
    let export = directory.appendingPathComponent("saved.pdf")
    try makePDF(first, pages: 2, text: "COMPLETED DOCUMENT")
    try makePDF(second, pages: 1, text: "NEXT DOCUMENT")
    let originalBytes = try Data(contentsOf: first)
    let suiteName = "Transall.ImportAfterCompletion.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    var destination = first
    let model = AppModel(
      backend: NativeDocumentEngine(
        dataDirectoryOverride: directory.appendingPathComponent("jobs"),
        credentialStore: EmptyWorkbenchCredentials()), preferences: preferences,
      resultDestinationPicker: { _ in destination }, resultRevealer: { _ in })
    await model.start()
    defer { model.prepareForTermination() }
    model.selectTask(.editPDF)
    await model.importDocuments([first])
    await model.runJob()
    try await waitFor { model.currentJob?.isFinished == true }
    let job = try #require(model.currentJob)
    try #require(job.status == "done")
    await model.refreshPreview()
    try await waitFor { model.previewPages.count == 2 }
    let pages = model.previewPages.map(\.url)
    let originals = model.resultOriginalDocuments?.map(\.url)
    await model.importDocuments([second], appending: appending)
    #expect(model.documents.map(\.url) == (appending ? [first, second] : [second]))
    #expect(model.currentJob?.id == job.id)
    #expect(model.canStartSavingResult)
    #expect(model.previewPages.map(\.url) == pages)
    #expect(model.resultOriginalDocuments?.map(\.url) == originals)
    #expect(preferences.string(forKey: "transall.native.lastJobId") == job.id)
    // Duplicate imports must not discard the result either.
    await model.importDocuments([second], appending: true)
    #expect(model.currentJob?.id == job.id)
    model.startSavingResult()
    #expect(!model.isSaving)
    #expect(model.errorMessage != nil)
    #expect(try Data(contentsOf: first) == originalBytes)
    destination = export
    model.startSavingResult()
    try await waitFor { !model.isSaving }
    #expect(model.errorMessage == nil)
    let saved = try #require(PDFDocument(url: export))
    #expect(saved.pageCount == 2)
    #expect(saved.string?.contains("COMPLETED DOCUMENT") == true)
    #expect(saved.string?.contains("NEXT DOCUMENT") == false)
  }

  @Test @MainActor
  func parallelProgressIsIndependentPerJobAndClearsOnCompletionOrCancellation() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.pdf")
    let second = directory.appendingPathComponent("second.pdf")
    try makePDF(first, pages: 1, text: "FIRST")
    try makePDF(second, pages: 1, text: "SECOND")
    let gate = ProgressTestGate()
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: directory.appendingPathComponent("jobs"),
      credentialStore: EmptyWorkbenchCredentials(),
      jobProcessor: { route, inputs, options, output, key in
        try await withThrowingTaskGroup(of: Void.self) { group in
          for worker in 1...2 {
            group.addTask {
              await ProcessingProgress.report(
                inputs[0].lastPathComponent, fraction: Double(worker) / 3,
                id: "worker-\(worker)")
              try await gate.wait()
            }
          }
          try await group.waitForAll()
        }
        return try await NativeDocumentProcessor.process(
          route: route, inputs: inputs, options: options, outputURL: output, apiKey: key)
      })
    await engine.start()
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let firstJob = try await engine.createJob(
      route: route,
      files: [SelectedDocument(url: first, size: Int64(Data(contentsOf: first).count))],
      options: JobOptions())
    let secondJob = try await engine.createJob(
      route: route,
      files: [SelectedDocument(url: second, size: Int64(Data(contentsOf: second).count))],
      options: JobOptions())
    try await waitFor {
      engine.taskProgress[firstJob.id]?.count == 2 && engine.taskProgress[secondJob.id]?.count == 2
    }
    let firstLines = try #require(engine.taskProgress[firstJob.id])
    let secondLines = try #require(engine.taskProgress[secondJob.id])
    let expectedFractions: [Double?] = [1.0 / 3, 2.0 / 3]
    #expect(firstLines.map(\.fraction) == expectedFractions)
    #expect(firstLines.allSatisfy { $0.title.contains("first") })
    #expect(secondLines.allSatisfy { $0.title.contains("second") })
    _ = try engine.cancelJob(id: firstJob.id)
    await gate.release()
    try await waitFor {
      engine.taskProgress[firstJob.id] == nil
        && (try? engine.job(id: secondJob.id).status) == "done"
    }
    #expect(engine.taskProgress[secondJob.id] == nil)
    #expect(try engine.job(id: firstJob.id).status == "cancelled")
  }

  @Test
  func translationProgressCountsCompletedChunksAndMissingRegionRetries() async throws {
    let events = ProgressEventRecorder()
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { request in
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (Data(#"{"choices":[{"message":{"content":"译文"}}]}"#.utf8), response)
      })
    let text = String(repeating: "a", count: 24_001)
    _ = try await service.translate(text, source: "en", target: "zh", glossary: "") { fraction in
      await events.record(TaskProgressLine(title: "翻译", fraction: fraction))
    }
    let chunkFractions = await events.snapshot().compactMap(\.fraction)
    let count = TranslationService.chunks(text).count
    #expect(chunkFractions.count == count)
    #expect(chunkFractions.first == 1.0 / Double(count))
    #expect(chunkFractions.last == 1)

    let regionEvents = ProgressEventRecorder()
    let responses = ProgressRegionResponses()
    let regions = (1...2).map { index in
      PDFTranslationRegion(
        id: "region-\(index)", pageIndex: 0, kind: .nativeText,
        bounds: CGRect(x: 0, y: index * 20, width: 100, height: 14),
        sourceText: "Source \(index)", preferredFontSize: 10)
    }
    let regionService = TranslationService(
      provider: "deepseek", apiKey: "test-key", requestSender: { try await responses.send($0) })
    _ = try await ProcessingProgress.$reporter.withValue(
      { await regionEvents.record($0) },
      operation: {
        try await regionService.translateRegions(regions, source: "en", target: "zh", glossary: "")
      })
    let reported = await regionEvents.snapshot().filter { $0.id == "translation-total" }
    #expect(reported.compactMap(\.fraction) == [0, 0.5, 1])
    #expect(reported.last?.title.contains("已完成 1/1 页") == true)
  }

  @Test
  func sourcePreviewUsesAnIndependentCopyAndRejectsChangedOrLinkedFiles() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    let data = Data("original document".utf8)
    try data.write(to: source)
    let document = SelectedDocument(url: source, size: Int64(data.count))
    let snapshot = try await InputPreviewSnapshot.create(for: document)
    defer { try? FileManager.default.removeItem(at: snapshot.directory) }
    #expect(snapshot.url != source)
    try Data("changed document with another size".utf8).write(to: source)
    #expect(try Data(contentsOf: snapshot.url) == data)
    await #expect(throws: (any Error).self) { try await InputPreviewSnapshot.create(for: document) }
    let link = directory.appendingPathComponent("linked.pdf")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
    await #expect(throws: (any Error).self) {
      try await InputPreviewSnapshot.create(
        for: SelectedDocument(url: link, size: Int64(data.count)))
    }
  }

  @Test @MainActor
  func pdfReloadClearsSearchAndPageState() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.pdf")
    let second = directory.appendingPathComponent("second.pdf")
    try makePDF(first, pages: 3, text: "first document")
    try makePDF(second, pages: 1, text: "second document")
    _ = NSApplication.shared
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
    let controller = InspectionPDFController()
    defer { controller.detach() }
    controller.attach(to: view, url: first, initialPage: 3)
    try await waitFor { !controller.loading }
    controller.query = "first"
    try await waitFor { !controller.searching }
    #expect(controller.matchCount == 3)
    controller.attach(to: view, url: second, initialPage: 1)
    try await waitFor { !controller.loading }
    #expect(controller.loadedURL == second)
    #expect(controller.query.isEmpty)
    #expect(controller.matchCount == 0)
    #expect(controller.pageCount == 1)
    #expect(controller.currentPage == 1)
    #expect(view.document?.string?.contains("second document") == true)
  }

  @Test @MainActor
  func textResultIsVerifiedAndTaskConfigurationRestoresWithoutOriginalAccess() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = directory.appendingPathComponent("source.pdf")
    try makePDF(input, pages: 2, text: "transall sample")
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: directory.appendingPathComponent("jobs"),
      credentialStore: EmptyWorkbenchCredentials())
    await engine.start()
    defer { engine.prepareForTermination() }
    let route = try #require(
      NativeCapabilities.routes.first { $0.source == "pdf" && $0.target == "md" })
    let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let job = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: Int64(size))], options: JobOptions())
    try await waitFor { (try? engine.job(id: job.id).isFinished) == true }
    #expect(try engine.job(id: job.id).status == "done")
    let configuration = try engine.taskConfiguration(jobID: job.id)
    #expect(configuration.route == route)
    let snapshot = try await engine.inspectionSnapshot(jobID: job.id)
    defer { try? FileManager.default.removeItem(at: snapshot.directory) }
    let result = try #require(snapshot.result)
    #expect(result.pathExtension == "md")
    #expect(try String(contentsOf: result, encoding: .utf8).contains("transall sample"))
    let suiteName = "Transall.WorkbenchTests.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    preferences.set(job.id, forKey: "transall.native.lastJobId")
    let model = AppModel(backend: engine, preferences: preferences)
    await model.start()
    defer { model.prepareForTermination() }
    #expect(model.selectedTask == .extractMarkdown)
    #expect(model.selection.source == "pdf")
    #expect(model.currentJob?.id == job.id)
    #expect(model.documents.isEmpty)
    #expect(model.requiresNewResultDestination)
    #expect(TaskToolbarAction(model: model) == .save)
    #expect(model.canStartSavingResult)
    #expect(model.reverseFormats(expectedSelection: model.selection))
    #expect(model.selection == RouteSelection(source: "md", target: "pdf"))
    #expect(try engine.job(id: job.id).status == "done")
    #expect(model.currentJob == nil)
    let output = try #require(engine.job(id: job.id).output)
    let storedResult = directory.appendingPathComponent("jobs/Jobs/\(job.id)/\(output)")
    try Data("modified result".utf8).write(to: storedResult)
    await #expect(throws: (any Error).self) { try await engine.inspectionSnapshot(jobID: job.id) }
  }

  @Test @MainActor
  func firstLaunchWaitsForFormatSelection() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let suiteName = "Transall.WorkbenchLaunch.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let model = AppModel(
      backend: NativeDocumentEngine(
        dataDirectoryOverride: directory,
        credentialStore: EmptyWorkbenchCredentials()), preferences: preferences)
    await model.start()
    defer { model.prepareForTermination() }
    #expect(model.selection == RouteSelection())
    #expect(model.route == nil)
    #expect(!model.canSelectDocuments)
  }

  @Test @MainActor
  func orbitFiltersRoutesAndReplacesDraftsSafely() {
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    #expect(!model.canChooseFormat("ocr"))
    model.chooseFormat("pdf", animated: false)
    #expect(model.selection == RouteSelection(source: "pdf", target: nil))
    #expect(model.canChooseFormat("pdf"))
    #expect(model.canChooseFormat("translated_pdf"))
    #expect(!model.canChooseFormat("html"))
    model.chooseFormat("pdf", animated: false)
    #expect(model.route?.kind == "pdf_edit")
    model.documents = [SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 1)]
    model.options.watermark = "old draft"
    model.resetFormatSelection(keepingSource: true)
    #expect(model.selection == RouteSelection(source: "pdf", target: nil))
    #expect(model.documents.isEmpty)
    #expect(model.options.watermark.isEmpty)
    model.chooseFormat("md", animated: false)
    #expect(model.selectedTask == .extractMarkdown)
    model.isSubmitting = true
    model.resetFormatSelection()
    #expect(model.route?.target == "md")
    model.isSubmitting = false
    model.chooseFormat("image", animated: false)
    #expect(model.selection == RouteSelection(source: "image", target: nil))
    #expect(!model.canChooseFormat("translated_pdf"))
    model.chooseFormat("pdf", animated: false)
    #expect(model.route?.kind == "image_to_pdf")
  }

  @Test @MainActor
  func draggingFormatsSupportsEitherOrderAndEveryRoute() {
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    for route in NativeCapabilities.routes where route.enabled {
      model.resetFormatSelection()
      #expect(model.dropFormat(route.target, to: .target))
      #expect(model.selection.source == nil)
      #expect(model.route == nil)
      #expect(model.dropFormat(route.source, to: .source))
      #expect(model.route == route)
      model.resetFormatSelection()
      #expect(model.dropFormat(route.source, to: .source))
      #expect(model.dropFormat(route.target, to: .target))
      #expect(model.route == route)
    }
  }

  @Test @MainActor
  func slotMovesSwapRemoveAndRejectInvalidRoutesWithoutClearingDrafts() {
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    #expect(model.dropFormat("pdf", to: .source))
    #expect(model.dropFormat("md", to: .target))
    #expect(model.dropFormat("pdf", from: .source, to: .target))
    #expect(model.selection == RouteSelection(source: "md", target: "pdf"))
    #expect(model.dropFormat("pdf", from: .target, to: nil))
    #expect(model.selection == RouteSelection(source: "md", target: nil))
    #expect(model.dropFormat("md", from: .source, to: .target))
    #expect(model.selection == RouteSelection(source: nil, target: "md"))
    #expect(model.dropFormat("image", to: .source))
    model.documents = [SelectedDocument(url: URL(fileURLWithPath: "/tmp/drag.png"), size: 1)]
    model.options.watermark = "preserve draft"
    let selection = model.selection
    #expect(!model.dropFormat("image", from: .source, to: .target))
    #expect(!model.dropFormat("html", to: .target))
    #expect(!model.dropFormat("pdf", from: .source, to: nil))
    #expect(!model.dropFormat("pdf", to: nil))
    #expect(model.dropFormat("image", from: .source, to: .source))
    #expect(model.dropFormat("md", to: .target))
    #expect(model.selection == selection)
    #expect(model.documents.count == 1)
    #expect(model.options.watermark == "preserve draft")
    #expect(model.dropFormat("pdf", to: .target))
    #expect(model.documents.isEmpty)
    #expect(model.options.watermark.isEmpty)
  }

  @Test @MainActor
  func formatDropsRespectOperationLocks() async {
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    model.selectTask(.editPDF)
    let initial = model.selection
    model.startDocumentImport([URL(fileURLWithPath: "/tmp/format-drag-lock.pdf")])
    #expect(model.isImporting)
    #expect(!model.dropFormat("md", to: .target))
    await model.cancelDocumentImport()
    model.isSubmitting = true
    #expect(!model.dropFormat("pdf", from: .source, to: nil))
    model.isSubmitting = false
    model.isDeletingJob = true
    #expect(!model.dropFormat("md", to: .target))
    #expect(model.selection == initial)
  }

  @Test @MainActor
  func orbitAvailabilityFollowsTheSlotBeingFilledAndOperationLocks() {
    let model = AppModel()
    func available(_ slot: FormatRouteSlot) -> Set<String> {
      Set(
        NativeFormatOrbit.formats.filter {
          !model.orbitDestinations(for: $0, activeSlot: slot).isEmpty
        })
    }
    #expect(available(.source) == Set(NativeFormatOrbit.formats))
    #expect(model.dropFormat("pdf", to: .source))
    #expect(available(.target) == ["pdf", "translated_pdf", "ocr", "md"])
    #expect(available(.source) == ["pdf", "image", "md", "html", "data", "word", "ppt", "excel"])
    // The PDF module leaves the ring, but the empty central slot can reuse it for PDF editing.
    #expect(model.orbitDestinations(for: "pdf", activeSlot: .target) == [.target])
    #expect(model.dropFormat("pdf", to: .target))
    #expect(model.selection == RouteSelection(source: "pdf", target: "pdf"))
    model.resetFormatSelection()
    #expect(model.dropFormat("ocr", to: .target))
    #expect(available(.source) == ["pdf", "image"])
    model.isSubmitting = true
    #expect(available(.source).isEmpty)
    model.isSubmitting = false
    #expect(available(.source) == ["pdf", "image"])
  }

  @Test @MainActor
  func reversalIsAtomicClearsDraftAndRejectsReplayedRequests() {
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    model.selectTask(.extractMarkdown)
    let before = model.selection
    var observedSelections: [RouteSelection] = []
    let observation = model.$selection.dropFirst().sink { observedSelections.append($0) }
    defer { observation.cancel() }
    model.documents = [SelectedDocument(url: URL(fileURLWithPath: "/tmp/reverse.pdf"), size: 1)]
    model.options.watermark = "old draft"
    model.previewPages = [PreviewPage(page: 1, url: "old-preview.png")]
    #expect(model.formatReversalDisabledReason == nil)
    #expect(model.reverseFormats(expectedSelection: before))
    #expect(model.selection == RouteSelection(source: "md", target: "pdf"))
    #expect(observedSelections == [before.reversed])
    #expect(model.documents.isEmpty)
    #expect(model.options.watermark.isEmpty)
    #expect(model.previewPages.isEmpty)
    #expect(!model.reverseFormats(expectedSelection: before))
    #expect(model.reverseFormats(expectedSelection: before.reversed))
    #expect(model.selection == before)
  }

  @Test @MainActor
  func reversalRejectsUnsupportedAndLockedChangesWithoutClearingDrafts() async {
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    model.selectTask(.createPDF)
    let incompatible = model.selection
    model.documents = [SelectedDocument(url: URL(fileURLWithPath: "/tmp/reverse.png"), size: 1)]
    model.options.watermark = "keep draft"
    #expect(model.formatReversalDisabledReason == "暂不支持 PDF → 图片")
    #expect(!model.reverseFormats(expectedSelection: incompatible))
    #expect(model.documents.count == 1)
    #expect(model.options.watermark == "keep draft")
    model.selectTask(.extractMarkdown)
    let reversible = model.selection
    model.isSubmitting = true
    #expect(model.formatReversalDisabledReason != nil)
    #expect(!model.reverseFormats(expectedSelection: reversible))
    model.isSubmitting = false
    model.isDeletingJob = true
    #expect(!model.reverseFormats(expectedSelection: reversible))
    model.isDeletingJob = false
    model.startDocumentImport([URL(fileURLWithPath: "/tmp/reversal-import.pdf")])
    #expect(model.isImporting)
    #expect(!model.reverseFormats(expectedSelection: reversible))
    await model.cancelDocumentImport()
    #expect(model.selection == reversible)
    #expect(model.reverseFormats(expectedSelection: reversible))
  }

  @Test @MainActor
  func hourglassWaistRejectsDropsAndDoesNotRemoveOccupiedSlots() {
    let model = AppModel()
    model.selectTask(.extractMarkdown)
    let initial = model.selection
    for size in [CGFloat(300), 431, 580] {
      let layout = HourglassLayout(orbitSize: size)
      #expect(layout.frame.height == 168)
      #expect(layout.frame.width <= 200)
      for slot in FormatRouteSlot.allCases {
        let frame = layout.slotFrame(slot)
        #expect(layout.slot(at: CGPoint(x: frame.midX, y: frame.midY)) == slot)
      }
      let waist = CGPoint(x: size / 2, y: size / 2)
      #expect(layout.slot(at: waist) == nil)
      #expect(model.orbitDropSelection(for: "pdf", from: .source, at: waist, layout: layout) == nil)
      #expect(layout.slot(at: layout.flipCenter) == nil)
      #expect(model.selection == initial)
    }
  }

  @Test(arguments: [
    "pdf:pdf", "pdf:ocr", "image:ocr", "pdf:md", "image:md",
    "image:pdf", "md:pdf", "html:pdf", "data:pdf", "html:md", "data:md",
  ]) @MainActor
  func localTaskRoutesProduceInspectableExportsWithoutChangingInputs(pair: String) async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let parts = pair.split(separator: ":").map(String.init)
    let selection = RouteSelection(source: parts[0], target: parts[1])
    let task = try #require(WorkbenchTask.matching(selection))
    let pdf = directory.appendingPathComponent("sample.pdf")
    try makePDF(pdf, pages: 1, text: "WORKSPACE SAMPLE")
    let input: URL
    switch parts[0] {
    case "pdf": input = pdf
    case "image":
      input = directory.appendingPathComponent("sample.png")
      let source = try #require(CGPDFDocument(pdf as CFURL))
      let page = try #require(source.page(at: 1))
      let raster = try #require(NativeDocumentProcessor.render(page: page, maximumDimension: 2100))
      let bitmap = NSBitmapImageRep(cgImage: raster)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(to: input)
    default:
      let ext = parts[0] == "data" ? "txt" : parts[0]
      input = directory.appendingPathComponent("sample.\(ext)")
      let content = parts[0] == "html" ? "<h1>WORKSPACE SAMPLE</h1>" : "WORKSPACE SAMPLE"
      try Data(content.utf8).write(to: input)
    }
    let original = try Data(contentsOf: input)
    let outputExtension = parts[1] == "md" ? "md" : "pdf"
    let export = directory.appendingPathComponent("export.\(outputExtension)")
    let suiteName = "Transall.WorkbenchExport.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let model = AppModel(
      backend: NativeDocumentEngine(
        dataDirectoryOverride: directory.appendingPathComponent("jobs"),
        credentialStore: EmptyWorkbenchCredentials()), preferences: preferences,
      resultDestinationPicker: { _ in export }, resultRevealer: { _ in })
    await model.start()
    defer { model.prepareForTermination() }
    model.selectTask(task, source: parts[0])
    #expect(TaskToolbarAction(model: model) == .addFiles)
    await model.importDocuments([input])
    #expect(TaskToolbarAction(model: model) == .start)
    model.options.ocrLanguage = "en-US"
    model.startJob()
    #expect(TaskToolbarAction(model: model) == .cancelSubmission)
    try await waitFor { model.currentJob?.isFinished == true && !model.isSubmitting }
    let job = try #require(model.currentJob)
    try #require(job.status == "done", "\(pair): \(job.error ?? "unknown failure")")
    #expect(TaskToolbarAction(model: model) == .save)
    #expect(!model.showInputPreview)
    let snapshot = try await model.backend.inspectionSnapshot(jobID: job.id)
    defer { try? FileManager.default.removeItem(at: snapshot.directory) }
    let result = try #require(snapshot.result)
    #expect(result.pathExtension == outputExtension)
    model.startSavingResult()
    #expect(TaskToolbarAction(model: model) == .cancelSaving)
    try await waitFor { !model.isSaving }
    #expect(TaskToolbarAction(model: model) == .save)
    #expect(model.errorMessage == nil)
    #expect(try Data(contentsOf: export) == Data(contentsOf: result))
    #expect(try Data(contentsOf: input) == original)
    if outputExtension == "pdf" {
      let document = try #require(PDFDocument(url: export))
      #expect(document.pageCount == 1)
      if parts[0] != "image" || parts[1] == "ocr" {
        #expect(document.string?.contains("WORKSPACE SAMPLE") == true)
      }
    } else {
      #expect(try String(contentsOf: export, encoding: .utf8).contains("WORKSPACE SAMPLE"))
    }
  }

  @Test(arguments: [0, 90, 180, 270])
  func ocrRasterPreservesContentCoverageWhenUpscaling(rotation: Int) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("coverage.pdf")
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var box = CGRect(x: 0, y: 0, width: 500, height: 700)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 40, y: 60, width: 420, height: 540))
    context.endPDFPage()
    context.closePDF()
    let document = try #require(PDFDocument(url: url))
    document.page(at: 0)?.rotation = rotation
    #expect(document.write(to: url))
    let source = try #require(CGPDFDocument(url as CFURL))
    let page = try #require(source.page(at: 1))
    let image = try #require(
      NativeDocumentProcessor.render(page: page, maximumDimension: 2100))
    let data = try #require(image.dataProvider?.data)
    let bytes = try #require(CFDataGetBytePtr(data))
    var minX = image.width
    var minY = image.height
    var maxX = 0
    var maxY = 0
    for y in stride(from: 0, to: image.height, by: 4) {
      for x in stride(from: 0, to: image.width, by: 4) {
        let index = y * image.bytesPerRow + x * 4
        if bytes[index] < 64 && bytes[index + 1] < 64 && bytes[index + 2] < 64 {
          minX = min(minX, x)
          maxX = max(maxX, x)
          minY = min(minY, y)
          maxY = max(maxY, y)
        }
      }
    }
    let widthRatio = Double(maxX - minX) / Double(image.width)
    let heightRatio = Double(maxY - minY) / Double(image.height)
    let quarterTurn = rotation == 90 || rotation == 270
    #expect(abs(widthRatio - (quarterTurn ? 540.0 / 700 : 420.0 / 500)) < 0.02)
    #expect(abs(heightRatio - (quarterTurn ? 420.0 / 500 : 540.0 / 700)) < 0.02)
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "transall-workbench-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @MainActor private func waitFor(_ predicate: () -> Bool) async throws {
    for _ in 0..<300 {
      if predicate() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("Workbench operation did not finish")
  }

  private func makePDF(_ url: URL, pages: Int, text: String) throws {
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var bounds = CGRect(x: 0, y: 0, width: 500, height: 700)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    for page in 1...pages {
      context.beginPDFPage(nil)
      let line = NSAttributedString(
        string: "\(text) - page \(page)", attributes: [.font: NSFont.systemFont(ofSize: 18)])
      context.textPosition = CGPoint(x: 40, y: 620)
      CTLineDraw(CTLineCreateWithAttributedString(line), context)
      context.endPDFPage()
    }
    context.closePDF()
  }
}

private struct EmptyWorkbenchCredentials: ProviderCredentialStoring {
  func value(for credential: ProviderCredential) throws -> String { "" }
  func setValue(_ value: String, for credential: ProviderCredential) throws {}
}

private actor ProgressTestGate {
  private var released = false

  func release() { released = true }

  func wait() async throws {
    while !released { try await Task.sleep(for: .milliseconds(10)) }
    try Task.checkCancellation()
  }
}

private actor ProgressEventRecorder {
  private var events: [TaskProgressLine] = []
  func record(_ event: TaskProgressLine) { events.append(event) }
  func snapshot() -> [TaskProgressLine] { events }
}

private actor ProgressRegionResponses {
  private var count = 0
  func send(_ request: URLRequest) throws -> (Data, URLResponse) {
    count += 1
    let content = try JSONSerialization.data(withJSONObject: [
      "items": [["id": "region-\(count)", "text": "译文"]]
    ])
    let data = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": String(decoding: content, as: UTF8.self)]]]
    ])
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (data, response)
  }
}
