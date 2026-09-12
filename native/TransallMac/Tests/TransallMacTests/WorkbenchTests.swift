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

  @Test
  func orbitRedistributesRemainingFormatsAndRestoresTheirOrder() {
    let initial = NativeFormatOrbit.remainingFormats(for: RouteSelection())
    #expect(initial == NativeFormatOrbit.formats)
    for lifted in initial {
      let remaining = NativeFormatOrbit.remainingFormats(for: RouteSelection(), lifting: lifted)
      #expect(remaining.count == NativeFormatOrbit.formats.count - 1)
      #expect(!remaining.contains(lifted))
      for (index, format) in remaining.enumerated() {
        let next = remaining[(index + 1) % remaining.count]
        let currentAngle = NativeFormatOrbit.angle(of: format, among: remaining)
        var nextAngle = NativeFormatOrbit.angle(of: next, among: remaining)
        if index == remaining.count - 1 { nextAngle += .pi * 2 }
        #expect(abs(nextAngle - currentAngle - .pi * 2 / Double(remaining.count)) < 0.0001)
      }
    }
    let selected = RouteSelection(source: "pdf", target: "md")
    #expect(
      NativeFormatOrbit.remainingFormats(for: selected).count == NativeFormatOrbit.formats.count - 2
    )
    #expect(!NativeFormatOrbit.remainingFormats(for: selected).contains("pdf"))
    #expect(!NativeFormatOrbit.remainingFormats(for: selected).contains("md"))
    #expect(
      NativeFormatOrbit.remainingFormats(for: selected, lifting: "image").count == NativeFormatOrbit
        .formats.count - 3)
    #expect(
      NativeFormatOrbit.remainingFormats(for: RouteSelection(source: "pdf", target: "pdf")).count
        == NativeFormatOrbit.formats.count - 1)
    #expect(NativeFormatOrbit.remainingFormats(for: RouteSelection()) == initial)
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

  @Test
  func dockingStrengthGrowsContinuouslyAndStopsAtTheSlotBoundary() {
    let frame = CGRect(x: 100, y: 100, width: 160, height: 68)
    #expect(NativeFormatOrbit.dockingStrength(at: CGPoint(x: 180, y: 134), to: frame) == 1)
    #expect(NativeFormatOrbit.dockingStrength(at: CGPoint(x: 100, y: 134), to: frame) == 1)
    #expect(NativeFormatOrbit.dockingStrength(at: CGPoint(x: 36, y: 134), to: frame) == 0)
    #expect(NativeFormatOrbit.dockingStrength(at: CGPoint(x: 68, y: 134), to: frame) == 0.5)
    var previous: CGFloat = 0
    for x in stride(from: CGFloat(0), through: 100, by: 1) {
      let strength = NativeFormatOrbit.dockingStrength(at: CGPoint(x: x, y: 134), to: frame)
      #expect(strength >= previous && strength <= 1)
      previous = strength
    }
    #expect(NativeFormatOrbit.dockingStrength(at: CGPoint(x: 36, y: 36), to: frame) == 0)
  }

  @Test
  func waistApproachIsGradualAndSymmetric() {
    let frame = CGRect(x: 100, y: 100, width: 160, height: 68)
    var previous: CGFloat = 0
    for distance in stride(from: CGFloat(98), through: 0, by: -1) {
      let source = NativeFormatOrbit.dockingStrength(
        at: CGPoint(x: frame.midX, y: frame.midY + distance), to: frame, slot: .source)
      let target = NativeFormatOrbit.dockingStrength(
        at: CGPoint(x: frame.midX, y: frame.midY - distance), to: frame, slot: .target)
      #expect(source == target)
      #expect(source >= previous && source <= 1)
      #expect(source - previous < 0.025)
      previous = source
    }
    #expect(previous == 1)
    let edge = NativeFormatOrbit.dockingStrength(
      at: CGPoint(x: frame.midX, y: frame.maxY), to: frame, slot: .source)
    #expect(edge > 0.45 && edge < 0.6)
  }

  @Test
  func exitClearanceKeepsStationaryModulesOutsideAttachedBulbs() {
    for size: CGFloat in [300, 431, 580] {
      let before = RouteSelection(source: "data", target: "pdf")
      for after in [RouteSelection(source: "image", target: "pdf"), RouteSelection()] {
        let plan = OrbitReturnPlan.make(
          before: before, after: after, order: NativeFormatOrbit.formats, size: size)
        for prepared in [true, false] {
          let formats = NativeFormatOrbit.remainingFormats(
            for: after, order: plan.order)
          let hidden = Set(plan.departures.map(\.format))
          let slots: Set<FormatRouteSlot> = prepared ? [.source] : Set(plan.departures.map(\.slot))
          let phase = OrbitExitClearance.phase(
            formats: formats, hidden: hidden, slots: slots, size: size)
          #expect(abs(phase) <= .pi / Double(formats.count) + 0.0001)
          let layout = HourglassLayout(orbitSize: size)
          let diameter = NativeFormatOrbit.moduleDiameter(size: size)
          for slot in slots {
            let mouth = slot == .source ? layout.frame.minY : layout.frame.maxY
            let corridor = CGRect(
              x: size / 2 - diameter / 2,
              y: slot == .source ? mouth - diameter * 1.16 : mouth,
              width: diameter, height: diameter * 1.16
            ).insetBy(dx: -8, dy: -8)
            for format in formats where !hidden.contains(format) {
              let angle = NativeFormatOrbit.angle(of: format, among: formats) + phase
              let node = CGRect(
                x: size / 2 + cos(angle) * size * 0.385 - diameter / 2,
                y: size / 2 + sin(angle) * size * 0.385 - diameter / 2,
                width: diameter, height: diameter)
              #expect(
                !node.intersects(corridor), "size \(size), \(format), \(slot), prepared \(prepared)"
              )
            }
          }
        }
      }
    }
  }

  @Test
  func replacementReservesOutletWithoutRotatingAcrossTheSeam() {
    let before = RouteSelection(source: "image", target: "pdf")
    let after = RouteSelection(source: "word", target: "pdf")
    let plan = OrbitReturnPlan.make(
      before: before, after: after, order: NativeFormatOrbit.formats, size: 300)
    let ring = NativeFormatOrbit.remainingFormats(for: after, order: plan.order)
    #expect(ring.first == "image")
    #expect(
      OrbitExitClearance.phase(
        formats: ring, hidden: ["image"], slots: [.source], size: 300) == 0)
    let previous = NativeFormatOrbit.remainingFormats(for: before, lifting: "word")
    #expect(ring.filter { $0 != "image" } == previous)
    for format in previous {
      let old = NativeFormatOrbit.angle(of: format, among: previous)
      let next = NativeFormatOrbit.angle(of: format, among: ring)
      let unwrapped = NativeFormatOrbit.nearestAngle(next, to: old)
      #expect(abs(unwrapped - old) <= 2 * .pi / Double(ring.count) + 0.0001)
    }
    let nearTop = 3 * Double.pi / 2 - 0.05
    let acrossTop = -Double.pi / 2 + 0.05
    let forward = NativeFormatOrbit.nearestAngle(acrossTop, to: nearTop)
    #expect(abs(forward - nearTop - 0.1) < 0.0001)
    #expect(abs(NativeFormatOrbit.nearestAngle(nearTop, to: forward) - nearTop) < 0.0001)
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
  func reversalHandlesEmptyIdenticalAndSingleSlotSelections() {
    let model = AppModel()
    #expect(model.formatReversalDisabledReason == "请先选择格式")
    #expect(!model.reverseFormats(expectedSelection: model.selection))
    model.selectTask(.editPDF)
    #expect(model.formatReversalDisabledReason == "源格式与目标格式相同")
    #expect(!model.reverseFormats(expectedSelection: model.selection))
    model.resetFormatSelection(keepingSource: true)
    #expect(model.reverseFormats(expectedSelection: model.selection))
    #expect(model.selection == RouteSelection(source: nil, target: "pdf"))
    #expect(model.reverseFormats(expectedSelection: model.selection))
    #expect(model.selection == RouteSelection(source: "pdf", target: nil))
    model.resetFormatSelection()
    #expect(model.dropFormat("ocr", to: .target))
    #expect(model.formatReversalDisabledReason == "OCR 不能用作源格式")
    #expect(!model.reverseFormats(expectedSelection: model.selection))
  }

  @Test @MainActor
  func moduleRolesDescribeEachEndIndependentlyAndIgnoreOperationLocks() {
    let model = AppModel()
    model.resetFormatSelection()
    #expect(model.orbitRoles(for: "image") == OrbitFormatRoles(source: true, target: false))
    #expect(model.orbitRoles(for: "ocr") == OrbitFormatRoles(source: false, target: true))
    #expect(model.orbitRoles(for: "md") == OrbitFormatRoles(source: true, target: true))
    #expect(model.orbitRoles(for: "pdf") == OrbitFormatRoles(source: true, target: true))
    #expect(model.orbitRoles(for: "unknown") == OrbitFormatRoles(source: false, target: false))
    model.dropFormat("image", to: .source)
    #expect(
      model.orbitRoles(for: "translated_pdf") == OrbitFormatRoles(source: false, target: false))
    #expect(model.orbitRoles(for: "md") == OrbitFormatRoles(source: true, target: true))
    model.dropFormat("md", to: .target)
    #expect(model.orbitRoles(for: "html") == OrbitFormatRoles(source: true, target: false))
    let before = NativeFormatOrbit.formats.map { model.orbitRoles(for: $0) }
    model.isSubmitting = true
    #expect(NativeFormatOrbit.formats.map { model.orbitRoles(for: $0) } == before)
    #expect(!model.dropFormat("pdf", to: .source))
  }

  @Test @MainActor
  func approachingFormatsPreviewRolesWithoutChangingDrafts() throws {
    let model = AppModel()
    model.resetFormatSelection()
    model.options.watermark = "1-3"
    let layout = HourglassLayout(orbitSize: 580)
    let source = layout.slotFrame(.source)
    let point = CGPoint(x: source.midX, y: source.midY)
    let docking = model.orbitDockingFeedback(
      for: "image", from: nil, at: point, layout: layout)
    let preview = try #require(
      model.orbitPreviewSelection(
        for: "image", from: nil, docking: docking))
    #expect(preview == RouteSelection(source: "image", target: nil))
    #expect(model.orbitRoles(for: "translated_pdf").target)
    #expect(!model.orbitRoles(for: "translated_pdf", selection: preview).target)
    #expect(model.selection == RouteSelection())
    #expect(model.options.watermark == "1-3")
    #expect(model.orbitPreviewSelection(for: "image", from: nil, docking: nil) == nil)

    #expect(model.dropFormat("pdf", to: .source))
    #expect(model.dropFormat("translated_pdf", to: .target))
    model.options.watermark = "2"
    let invalid = model.orbitDockingFeedback(
      for: "image", from: nil, at: point, layout: layout)
    #expect(model.orbitPreviewSelection(for: "image", from: nil, docking: invalid) == nil)
    #expect(model.selection == RouteSelection(source: "pdf", target: "translated_pdf"))
    #expect(model.options.watermark == "2")

    model.resetFormatSelection()
    #expect(model.dropFormat("image", to: .source))
    #expect(model.dropFormat("md", to: .target))
    let replacement = model.orbitDockingFeedback(
      for: "pdf", from: nil, at: point, layout: layout)
    let replaced = try #require(
      model.orbitPreviewSelection(
        for: "pdf", from: nil, docking: replacement))
    #expect(model.orbitRoles(for: "translated_pdf", selection: replaced).target)
    #expect(!model.orbitRoles(for: "translated_pdf").target)
    model.isSubmitting = true
    #expect(model.orbitPreviewSelection(for: "pdf", from: nil, docking: replacement) == nil)
  }

  @Test @MainActor
  func stretchedModulesMatchBothHourglassHalvesAndMorphThroughNeutral() {
    let layout = HourglassLayout(orbitSize: 580)
    let full = HourglassShape().path(in: layout.frame)
    for slot in FormatRouteSlot.allCases {
      let rect = CGRect(
        x: layout.frame.minX, y: layout.frame.minY + (slot == .source ? 0 : 84),
        width: layout.frame.width, height: 84)
      let module = OrbitModuleShape(slot: slot, amount: 1).path(in: rect)
      for x in stride(from: rect.minX + 0.7, to: rect.maxX, by: 3.3) {
        for y in stride(from: rect.minY + 0.7, to: rect.maxY, by: 3.3) {
          let point = CGPoint(x: x, y: y)
          #expect(module.contains(point) == full.contains(point))
        }
      }
    }
    let rect = CGRect(x: 0, y: 0, width: 94, height: 94)
    var morph = OrbitModuleShape(slot: .target, amount: 1)
    #expect(morph.animatableData == -1)
    morph.animatableData = 0
    #expect(morph.path(in: rect) == OrbitModuleShape(slot: .source, amount: 0).path(in: rect))
    #expect(morph.path(in: rect).contains(CGPoint(x: 90, y: 47)))
  }

  @Test @MainActor
  func releasePreservesMagneticPositionAndInvalidModulesNeverAttract() {
    let layout = HourglassLayout(orbitSize: 580)
    let anchor = CGPoint(x: 360, y: 340)
    let compatible = OrbitDockingTarget(
      slot: .target, frame: layout.slotFrame(.target),
      strength: 0.75, compatibility: .compatible)
    let displayed = OrbitDragGeometry.displayedPosition(
      anchor, docking: compatible, reduceMotion: false)
    #expect(displayed.x < anchor.x)
    #expect(displayed.y < anchor.y)
    let full = OrbitDockingTarget(
      slot: .target, frame: compatible.frame,
      strength: 1, compatibility: .compatible)
    let gentle = OrbitDragGeometry.displayedPosition(anchor, docking: full, reduceMotion: false)
    #expect(abs(gentle.x - (anchor.x + (full.presentationCenter.x - anchor.x) * 0.22)) < 0.000001)
    #expect(gentle != full.presentationCenter)
    let invalid = OrbitDockingTarget(
      slot: .target, frame: compatible.frame,
      strength: 1, compatibility: .incompatible)
    #expect(
      OrbitDragGeometry.displayedPosition(anchor, docking: invalid, reduceMotion: false) == anchor)
    #expect(
      OrbitDragGeometry.displayedPosition(anchor, docking: compatible, reduceMotion: true) == anchor
    )
    #expect(OrbitDragGeometry.ringDuration >= 0.48)
  }

  @Test @MainActor
  func replacementProximityUsesSameValidationWithoutMutatingDraft() throws {
    let model = AppModel()
    model.dropFormat("pdf", to: .source)
    model.dropFormat("md", to: .target)
    model.options.glossary = "retain until a valid drop"
    let selection = model.selection
    let layout = HourglassLayout(orbitSize: 431)
    let rect = layout.slotFrame(.target)
    let point = CGPoint(x: rect.midX + 20, y: rect.midY)
    let accepted = try #require(
      model.orbitDockingFeedback(for: "ocr", from: nil, at: point, layout: layout))
    #expect(accepted.slot == .target)
    #expect(accepted.compatibility == .compatible)
    #expect(accepted.strength == 1)
    let rejected = try #require(
      model.orbitDockingFeedback(for: "image", from: nil, at: point, layout: layout))
    #expect(rejected.slot == .target)
    #expect(rejected.compatibility == .incompatible)
    #expect(model.selection == selection)
    #expect(model.options.glossary == "retain until a valid drop")
    #expect(!model.dropFormat("image", to: .target))
    #expect(model.options.glossary == "retain until a valid drop")
    #expect(model.dropFormat("ocr", to: .target))
    #expect(model.options.glossary.isEmpty)
  }

  @Test
  func chamberHighlightMatchesFullMorphWhilePointerRetainsGentleAttraction() {
    for size: CGFloat in [300, 431, 580] {
      let layout = HourglassLayout(orbitSize: size)
      for slot in FormatRouteSlot.allCases {
        let docking = OrbitDockingTarget(
          slot: slot, frame: layout.slotFrame(slot), strength: 1,
          compatibility: .compatible)
        let dimensions = docking.moduleSize(diameter: 94, reduceMotion: false)
        for anchor in [CGPoint(x: 10, y: 20), CGPoint(x: 450, y: 390), CGPoint(x: 290, y: 290)] {
          let center = OrbitDragGeometry.displayedPosition(
            anchor, docking: docking, reduceMotion: false)
          #expect(
            abs(center.x - (anchor.x + (docking.presentationCenter.x - anchor.x) * 0.22)) < 0.000001
          )
          let actual = CGRect(
            x: docking.presentationCenter.x - dimensions.width / 2,
            y: docking.presentationCenter.y - dimensions.height / 2,
            width: dimensions.width, height: dimensions.height)
          #expect(abs(actual.minX - layout.frame.minX) < 0.000001)
          #expect(
            abs(actual.minY - (slot == .source ? layout.frame.minY : layout.frame.midY)) < 0.000001)
          #expect(actual.height == 84)
          #expect(actual == layout.chamberFrame(slot))
          #expect(docking.presentationFrame == layout.chamberFrame(slot))
          #expect(layout.slot(at: CGPoint(x: layout.frame.midX, y: layout.frame.midY)) == nil)
        }
      }
    }
  }

  @Test @MainActor
  func dockingDifferentiatesCompatibilityWithoutAcceptingInvalidFormats() throws {
    let model = AppModel()
    model.dropFormat("pdf", to: .source)
    let layout = HourglassLayout(orbitSize: 580)
    let target = layout.slotFrame(.target)
    let point = CGPoint(x: target.midX, y: target.midY)
    let compatible = try #require(
      model.orbitDockingFeedback(for: "md", from: nil, at: point, layout: layout))
    let incompatible = try #require(
      model.orbitDockingFeedback(for: "html", from: nil, at: point, layout: layout))
    #expect(compatible.compatibility == .compatible)
    #expect(
      compatible.moduleSize(diameter: 100, reduceMotion: false)
        == CGSize(width: target.width, height: 84))
    #expect(incompatible.compatibility == .incompatible)
    #expect(
      incompatible.moduleSize(diameter: 100, reduceMotion: false) == CGSize(width: 85, height: 100))
    #expect(
      incompatible.moduleSize(diameter: 100, reduceMotion: true) == CGSize(width: 100, height: 100))
    #expect(
      compatible.moduleSize(diameter: 100, reduceMotion: true) == CGSize(width: 100, height: 100))
    #expect(model.orbitDropSelection(for: "html", from: nil, at: point, layout: layout) == nil)
    #expect(model.orbitDestinations(for: "html", activeSlot: .target).isEmpty)
    #expect(!model.dropFormat("html", to: .target))
    #expect(model.selection == RouteSelection(source: "pdf", target: nil))
    #expect(model.orbitDockingFeedback(for: "md", from: nil, at: .zero, layout: layout) == nil)
    let occupiedEdge = CGPoint(x: target.midX, y: layout.slotFrame(.source).maxY - 1)
    #expect(
      model.orbitDockingFeedback(for: "md", from: nil, at: occupiedEdge, layout: layout)?.slot
        == .source)
    model.dropFormat("md", to: .target)
    #expect(
      model.orbitDockingFeedback(for: "ocr", from: nil, at: point, layout: layout)?.compatibility
        == .compatible)
    model.isSubmitting = true
    #expect(model.orbitDropSelection(for: "ocr", from: nil, at: point, layout: layout) == nil)
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

  @Test
  func returnedModuleKeepsTheChosenCircularNeighborsIncludingTheWraparoundGap() {
    for count in 3...6 {
      let ring = Array(NativeFormatOrbit.formats.dropFirst().prefix(count))
      for index in ring.indices {
        let angle = NativeFormatOrbit.angle(of: ring[index], among: ring) + .pi / Double(count)
        let point = CGPoint(x: 290 + cos(angle) * 230, y: 290 + sin(angle) * 230)
        let next = OrbitReturnPlan.inserting("pdf", into: ring, at: point, size: 580)
        let inserted = next.firstIndex(of: "pdf")!
        #expect(next[(inserted - 1 + next.count) % next.count] == ring[index])
        #expect(next[(inserted + 1) % next.count] == ring[(index + 1) % ring.count])
        #expect(next.filter { $0 != "pdf" } == ring)
        #expect(Set(next).count == next.count)
      }
    }
  }

  @Test
  func directReturnUsesTheDropGapAndDoesNotAlsoEjectTheDraggedModule() {
    let before = RouteSelection(source: "pdf", target: "md")
    let after = RouteSelection(source: nil, target: "md")
    let ring = NativeFormatOrbit.remainingFormats(for: before)
    let angle = NativeFormatOrbit.angle(of: ring[2], among: ring) + .pi / Double(ring.count)
    let point = CGPoint(x: 290 + cos(angle) * 230, y: 290 + sin(angle) * 230)
    let plan = OrbitReturnPlan.make(
      before: before, after: after, order: NativeFormatOrbit.formats,
      draggedFormat: "pdf", dropPoint: point, size: 580)
    let visible = NativeFormatOrbit.remainingFormats(for: after, order: plan.order)
    let index = visible.firstIndex(of: "pdf")!
    #expect(visible[index - 1] == ring[2])
    #expect(visible[index + 1] == ring[3])
    #expect(plan.departures.isEmpty)
    #expect(Set(plan.order) == Set(NativeFormatOrbit.formats))
    #expect(plan.order.count == NativeFormatOrbit.formats.count)
    // Later selections retain the user-chosen circular ordering.
    let later = OrbitReturnPlan.make(before: after, after: before, order: plan.order, size: 580)
    #expect(NativeFormatOrbit.remainingFormats(for: before, order: later.order) == ring)
  }

  @Test
  func replacementAndClearEjectOnlyFormatsNoLongerUsedByEitherChamber() {
    let before = RouteSelection(source: "pdf", target: "md")
    let replaced = OrbitReturnPlan.make(
      before: before, after: RouteSelection(source: "pdf", target: "ocr"),
      order: NativeFormatOrbit.formats, size: 580)
    #expect(replaced.departures == [OrbitReleasedFormat(format: "md", slot: .target)])
    let cleared = OrbitReturnPlan.make(
      before: before, after: RouteSelection(), order: replaced.order, size: 580)
    #expect(
      cleared.departures == [
        OrbitReleasedFormat(format: "pdf", slot: .source),
        OrbitReleasedFormat(format: "md", slot: .target),
      ])
    #expect(Set(cleared.order) == Set(NativeFormatOrbit.formats))
    let same = RouteSelection(source: "pdf", target: "pdf")
    let partial = OrbitReturnPlan.make(
      before: same, after: RouteSelection(source: "pdf", target: nil),
      order: cleared.order, size: 580)
    #expect(partial.departures.isEmpty)
    let both = OrbitReturnPlan.make(
      before: same, after: RouteSelection(), order: cleared.order, size: 580)
    #expect(both.departures == [OrbitReleasedFormat(format: "pdf", slot: .source)])
    let flipped = OrbitReturnPlan.make(
      before: before, after: before.reversed, order: cleared.order, size: 580)
    #expect(flipped.departures.isEmpty)
    #expect(
      flipped.order.filter { $0 != "pdf" && $0 != "md" }
        == cleared.order.filter { $0 != "pdf" && $0 != "md" })
  }

  @Test @MainActor
  func replacementPreparationIsReversibleAndDoesNotMutateTheDraft() throws {
    let model = AppModel()
    model.dropFormat("pdf", to: .source)
    model.dropFormat("md", to: .target)
    model.options.glossary = "keep this draft"
    model.documents = [SelectedDocument(url: URL(fileURLWithPath: "/tmp/prepare.pdf"), size: 1)]
    let before = model.selection
    let layout = HourglassLayout(orbitSize: 580)
    var last = -1.0
    for strength: CGFloat in [0, 0.2, 0.6, 1] {
      let docking = OrbitDockingTarget(
        slot: .target, frame: layout.slotFrame(.target),
        strength: strength, compatibility: .compatible)
      let preview = try #require(
        model.orbitPreparedRelease(for: "ocr", from: nil, docking: docking))
      #expect(preview.item == OrbitReleasedFormat(format: "md", slot: .target))
      #expect(preview.progress > last)
      #expect(preview.progress <= OrbitReleasePresentation.preparationLimit)
      #expect(preview.progress < OrbitDeparturePath.separation)
      #expect(preview.remainingDuration >= OrbitDragGeometry.ringDuration)
      last = preview.progress
    }
    let target = OrbitDockingTarget(
      slot: .target, frame: layout.slotFrame(.target),
      strength: 1, compatibility: .compatible)
    #expect(model.orbitPreparedRelease(for: "ocr", from: nil, docking: nil) == nil)
    #expect(model.orbitPreparedRelease(for: "html", from: nil, docking: target) == nil)
    #expect(model.orbitPreparedRelease(for: "md", from: .target, docking: target) == nil)
    #expect(model.selection == before)
    #expect(model.options.glossary == "keep this draft")
    #expect(model.documents.count == 1)
    model.isSubmitting = true
    #expect(model.orbitPreparedRelease(for: "ocr", from: nil, docking: target) == nil)
    #expect(OrbitReleasePresentation.settlementLimit > OrbitReleasePresentation.preparationLimit)
    #expect(OrbitReleasePresentation.settlementLimit < OrbitDeparturePath.separation)
  }

  @Test @MainActor
  func swapsAndFormatsRetainedInAnotherChamberDoNotPrepareAnEjection() {
    let model = AppModel()
    let layout = HourglassLayout(orbitSize: 580)
    let source = OrbitDockingTarget(
      slot: .source, frame: layout.slotFrame(.source),
      strength: 1, compatibility: .compatible)
    model.dropFormat("pdf", to: .source)
    model.dropFormat("md", to: .target)
    #expect(model.orbitPreparedRelease(for: "md", from: .target, docking: source) == nil)
    model.resetFormatSelection()
    model.dropFormat("pdf", to: .source)
    model.dropFormat("pdf", to: .target)
    #expect(model.orbitPreparedRelease(for: "image", from: nil, docking: source) == nil)
  }

  @Test @MainActor
  func extrusionStaysConnectedOutsideTheLipThenSeparatesBeforeTravel() {
    for size: CGFloat in [300, 431, 580] {
      let layout = HourglassLayout(orbitSize: size)
      let canvas = CGRect(x: 0, y: 0, width: size, height: size)
      for slot in FormatRouteSlot.allCases {
        let departure = OrbitDeparturePath(
          slot: slot,
          destination: CGPoint(x: size * 0.8, y: size * 0.3), layout: layout)
        let attached = OrbitExtrusionShape(departure: departure, progress: 0.49).path(in: canvas)
        let lipOutside = CGPoint(
          x: departure.mouth.x,
          y: departure.mouth.y + departure.direction * 2)
        let lipInside = CGPoint(
          x: departure.mouth.x,
          y: departure.mouth.y - departure.direction * 2)
        #expect(attached.contains(lipOutside))
        #expect(!attached.contains(lipInside))
        #expect(attached.contains(departure.point(at: 0.49)))
        let detached = OrbitExtrusionShape(
          departure: departure,
          progress: OrbitDeparturePath.separation
        ).path(in: canvas)
        #expect(!detached.contains(lipOutside))
        #expect(detached.contains(departure.point(at: OrbitDeparturePath.separation)))
        #expect(departure.moduleFrame(at: 1).width == departure.diameter)
        #expect(departure.neckWidth(at: 1) == 0)
      }
    }
  }

  @Test
  func releasedModulesInitiallyTravelOutOfTheirOwnChamberAndFinishAtTheRing() {
    for size: CGFloat in [300, 431, 580] {
      let layout = HourglassLayout(orbitSize: size)
      #expect(layout.slot(at: layout.flipCenter) == nil)
      #expect(layout.slot(at: layout.clearCenter) == nil)
      #expect(layout.clearCenter.y == layout.flipCenter.y)
      #expect(layout.flipCenter.x < layout.frame.midX)
      #expect(layout.clearCenter.x > layout.frame.midX)
      #expect(layout.flipCenter.x + layout.clearCenter.x == size)
      #expect(layout.clearCenter.x - layout.flipCenter.x > 64)
      for slot in FormatRouteSlot.allCases {
        let destination = CGPoint(x: size * 0.8, y: size * 0.2)
        let path = OrbitDeparturePath(slot: slot, destination: destination, layout: layout)
        let center = path.mouth
        #expect(path.point(at: 0) == center)
        #expect(path.neckWidth(at: 0.35) > path.neckWidth(at: 0.55))
        #expect(path.neckWidth(at: OrbitDeparturePath.separation) == 0)
        for progress in [0.1, 0.3, 0.5, OrbitDeparturePath.separation] {
          #expect(path.point(at: progress).x == center.x)
        }
        #expect(path.point(at: 1) == destination)
        if slot == .source {
          #expect(path.point(at: 0.01).y < center.y)
        } else {
          #expect(path.point(at: 0.01).y > center.y)
        }
      }
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
    await model.importDocuments([input])
    model.options.ocrLanguage = "en-US"
    model.startJob()
    try await waitFor { model.currentJob?.isFinished == true && !model.isSubmitting }
    let job = try #require(model.currentJob)
    try #require(job.status == "done", "\(pair): \(job.error ?? "unknown failure")")
    #expect(!model.showInputPreview)
    let snapshot = try await model.backend.inspectionSnapshot(jobID: job.id)
    defer { try? FileManager.default.removeItem(at: snapshot.directory) }
    let result = try #require(snapshot.result)
    #expect(result.pathExtension == outputExtension)
    model.startSavingResult()
    try await waitFor { !model.isSaving }
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
