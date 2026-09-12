import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import TransallMac

@Suite(.serialized)
struct DocumentInspectionTests {
  @Test
  func pageNavigationRejectsInvalidInputAndOnlyLinksEqualNonemptyDocuments() {
    #expect(InspectionNavigation.pageNumber(" 11 ", count: 12) == 11)
    for text in ["0", "-1", "13", "1.5", "abc", ""] {
      #expect(InspectionNavigation.pageNumber(text, count: 12) == nil)
    }
    #expect(InspectionNavigation.pageNumber("1", count: 0) == nil)
    #expect(InspectionNavigation.canSynchronize(12, 12))
    #expect(!InspectionNavigation.canSynchronize(0, 0))
    #expect(!InspectionNavigation.canSynchronize(12, 13))
  }

  @Test
  func linkedPositionUsesCropCoordinatesAndClampsPageMargins() throws {
    let location = try #require(
      InspectionNavigation.location(
        pageIndex: 10, point: CGPoint(x: 200, y: 360),
        bounds: CGRect(x: 50, y: 60, width: 300, height: 600)))
    #expect(location == InspectionLocation(pageIndex: 10, x: 0.5, y: 0.5))
    #expect(
      InspectionNavigation.point(location, bounds: CGRect(x: 20, y: 40, width: 600, height: 800))
        == CGPoint(x: 320, y: 440))
    #expect(
      InspectionNavigation.location(
        pageIndex: 0, point: CGPoint(x: -10, y: 900),
        bounds: CGRect(x: 0, y: 0, width: 300, height: 600))
        == InspectionLocation(pageIndex: 0, x: 0, y: 1))
    #expect(InspectionNavigation.location(pageIndex: 0, point: .zero, bounds: .zero) == nil)
    #expect(
      InspectionNavigation.location(
        pageIndex: 0, point: CGPoint(x: CGFloat.nan, y: 1),
        bounds: CGRect(x: 0, y: 0, width: 300, height: 600)) == nil)
  }

  @Test
  func matchNavigationWrapsInBothDirectionsAndHandlesNoMatches() {
    #expect(InspectionNavigation.matchIndex(current: nil, count: 0, forward: true) == nil)
    #expect(InspectionNavigation.matchIndex(current: nil, count: 3, forward: false) == 2)
    #expect(InspectionNavigation.matchIndex(current: 2, count: 3, forward: true) == 0)
    #expect(InspectionNavigation.matchIndex(current: 0, count: 3, forward: false) == 2)
    #expect(InspectionNavigation.matchIndex(current: 0, count: 1, forward: true) == 0)
  }

  @MainActor @Test
  func searchesNavigateEveryPageAndChangedQueriesDiscardOldMatches() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("inspection.pdf")
    try makePDF(file)
    _ = NSApplication.shared
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 650))
    view.displayMode = .singlePageContinuous
    let originalView = PDFView(frame: view.frame)
    originalView.displayMode = .singlePageContinuous
    let originalController = InspectionPDFController()
    originalController.attach(to: originalView, url: file, initialPage: 11)
    defer { originalController.detach() }
    let controller = InspectionPDFController()
    controller.attach(to: view, url: file, initialPage: 11)
    defer { controller.detach() }
    try await waitFor { !controller.loading && !originalController.loading }
    controller.onLocation = { location in originalController.receive(location) }
    originalController.onLocation = { location in controller.receive(location) }
    #expect(controller.pageCount == 12)
    #expect(controller.currentPage == 11)
    controller.query = "needle"
    try await waitFor { !controller.searching }
    #expect(controller.matchCount == 12)
    #expect(controller.matchIndex == 0)
    controller.moveMatch(forward: false)
    #expect(controller.matchIndex == 11)
    #expect(controller.currentPage == 12)
    #expect(originalView.currentSelection == nil)
    #expect(originalController.currentPage == 12)
    let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    #expect(view.page(for: center, nearest: true).map { view.document?.index(for: $0) } == 11)
    #expect(
      originalView.page(for: center, nearest: true).map { originalView.document?.index(for: $0) }
        == 11)
    controller.query = "missing"
    controller.query = "page 11 only"
    try await waitFor { !controller.searching }
    #expect(controller.matchCount == 1)
    #expect(controller.currentPage == 11)
    controller.query = ""
    #expect(controller.matchCount == 0)
    #expect(!controller.searching)
    #expect(view.currentSelection == nil)
    controller.query = String(repeating: "x", count: 257)
    #expect(!controller.searching)
    #expect(controller.searchNotice != nil)
  }

  @MainActor @Test
  func commonSearchTermsStopAtTheMatchLimitAndRemainNavigable() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("many-matches.pdf")
    try makePDF(file, pageCount: 22, matchesPerPage: 100)
    _ = NSApplication.shared
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 650))
    let controller = InspectionPDFController()
    controller.attach(to: view, url: file, initialPage: 1)
    defer { controller.detach() }
    try await waitFor { !controller.loading }
    controller.query = "needle"
    try await waitFor { !controller.searching }
    #expect(controller.matchCount == InspectionPDFController.maximumMatches)
    #expect(controller.searchNotice != nil)
    #expect(view.document?.isFinding == false)
    controller.moveMatch(forward: false)
    #expect(controller.matchIndex == InspectionPDFController.maximumMatches - 1)
    controller.query = "missing"
    try await waitFor { !controller.searching }
    #expect(controller.matchCount == 0)
    #expect(controller.searchNotice == nil)
  }

  @MainActor @Test
  func issueHighlightOnlyChangesInspectionDocumentAndDoesNotRelayBack() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("inspection.pdf")
    try makePDF(file)
    let originalBytes = try Data(contentsOf: file)
    _ = NSApplication.shared
    let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 650))
    let controller = InspectionPDFController()
    controller.attach(to: view, url: file, initialPage: 1)
    defer { controller.detach() }
    try await waitFor { !controller.loading }
    let issue = TranslationLayoutIssue(
      id: "region-11", pageIndex: 10,
      bounds: CGRect(x: 40, y: 600, width: 260, height: 24), sourceText: "needle",
      translatedText: "译文")
    let page = try #require(view.document?.page(at: 10))
    view.go(to: page)
    let destinationBeforeHighlight = view.currentDestination?.point
    let issueWasVisible = view.bounds.contains(view.convert(issue.bounds, from: page))
    controller.highlight(issue)
    #expect(controller.currentPage == 11)
    #expect(view.document?.page(at: 10)?.annotations.count == 1)
    if issueWasVisible {
      #expect(view.currentDestination?.point == destinationBeforeHighlight)
    }
    controller.highlight(issue)
    #expect(view.document?.page(at: 10)?.annotations.count == 1)
    let bottomIssue = TranslationLayoutIssue(
      id: "bottom-region", pageIndex: 10,
      bounds: CGRect(x: 40, y: 30, width: 80, height: 16), sourceText: "Bottom cell",
      translatedText: "页底译文")
    controller.highlight(bottomIssue)
    #expect(controller.currentPage == 11)
    #expect(view.bounds.intersects(view.convert(bottomIssue.bounds, from: page)))
    #expect(try Data(contentsOf: file) == originalBytes)
    var relays = 0
    controller.onLocation = { _ in relays += 1 }
    controller.receive(InspectionLocation(pageIndex: 2, x: 0, y: 1))
    #expect(controller.currentPage == 3)
    try await Task.sleep(for: .milliseconds(150))
    #expect(relays == 0)
    controller.detach()
    #expect(view.document == nil)
  }

  @MainActor
  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record("PDF inspection did not finish loading or searching within five seconds")
  }

  private func makePDF(_ url: URL, pageCount: Int = 12, matchesPerPage: Int = 1) throws {
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    var media = CGRect(x: 0, y: 0, width: 500, height: 700)
    let context = try #require(CGContext(consumer: consumer, mediaBox: &media, nil))
    for index in 1...pageCount {
      context.beginPDFPage(nil)
      for match in 0..<matchesPerPage {
        let text = NSAttributedString(
          string: matchesPerPage == 1 ? "needle / page \(index) only" : "needle",
          attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black,
          ])
        context.textPosition = CGPoint(x: 40 + (match % 5) * 80, y: 600 - (match / 5) * 24)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
      }
      context.endPDFPage()
    }
    context.closePDF()
  }
}
