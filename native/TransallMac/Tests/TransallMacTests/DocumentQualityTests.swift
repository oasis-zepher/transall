import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing

@testable import TransallMac

@Suite(.serialized)
struct DocumentQualityTests {
  @Test(arguments: [0, 90, 180, 270])
  func layoutPreservesPageGeometryAnnotationsAndOnlyTranslatedText(rotation: Int) throws {
    let directory = try sampleDirectory("geometry-\(rotation)")
    defer { removeTemporary(directory) }
    let source = directory.appendingPathComponent("source.pdf")
    let output = directory.appendingPathComponent("translated.pdf")
    try fixture(source, mediaBox: CGRect(x: 30, y: 40, width: 400, height: 320))
    let original = try #require(PDFDocument(url: source))
    let page = try #require(original.page(at: 0))
    page.rotation = rotation
    page.setBounds(CGRect(x: 50, y: 65, width: 350, height: 260), for: .cropBox)
    let link = PDFAnnotation(
      bounds: CGRect(x: 80, y: 255, width: 170, height: 25), forType: .link, withProperties: nil)
    link.url = URL(string: "https://example.org/document")
    page.addAnnotation(link)
    let note = PDFAnnotation(
      bounds: CGRect(x: 80, y: 130, width: 210, height: 35), forType: .freeText, withProperties: nil
    )
    note.contents = "Keep this annotation"
    note.font = NSFont(name: "Helvetica", size: 10)
    page.addAnnotation(note)
    #expect(original.write(to: source))
    let sourceDocument = try #require(PDFDocument(url: source))
    let regions = try PDFLayoutTranslation.extractRegions(
      document: sourceDocument,
      rasterDocument: #require(CGPDFDocument(source as CFURL)), languages: ["en-US"],
      recognizer: { _, _ in [] })
    #expect(!regions.isEmpty)
    let report = try PDFLayoutTranslation.writeTranslatedPDF(
      inputURL: source, regions: regions,
      translations: Dictionary(uniqueKeysWithValues: regions.map { ($0.id, "完整译文") }),
      outputURL: output)
    #expect(report.overflowRegionIDs.isEmpty)
    let result = try #require(PDFDocument(url: output))
    let before = try #require(sourceDocument.page(at: 0))
    let after = try #require(result.page(at: 0))
    #expect(after.rotation == rotation)
    // PDFKit normalizes a copied page's media origin on write and translates its boxes/annotations.
    let beforeMedia = before.bounds(for: .mediaBox)
    let afterMedia = after.bounds(for: .mediaBox)
    let offset = CGPoint(
      x: afterMedia.minX - beforeMedia.minX, y: afterMedia.minY - beforeMedia.minY)
    for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
      #expect(
        after.bounds(for: box) == before.bounds(for: box).offsetBy(dx: offset.x, dy: offset.y))
    }
    #expect(after.annotations.count == before.annotations.count)
    #expect(after.annotations.contains { $0.url == link.url })
    #expect(after.annotations.contains { $0.contents == note.contents })
    #expect(
      after.annotations.first { $0.url == link.url }?.bounds
        == link.bounds.offsetBy(dx: offset.x, dy: offset.y))
    #expect(result.string?.contains("译") == true)
    #expect(result.string?.contains("SOURCE HEADING") == false)
    #expect(result.string?.contains("OUTSIDE CROP") == false)
    #expect((try Data(contentsOf: output)).count < 1_000_000)
  }

  @Test
  func layoutRetainsDisjointRepeatedLabelsButDropsAnOverlaidDuplicate() throws {
    let directory = try sampleDirectory("deduplication")
    defer { removeTemporary(directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try fixture(source)
    let document = try #require(PDFDocument(url: source))
    let raster = try #require(CGPDFDocument(source as CFURL))
    let native = try PDFLayoutTranslation.extractRegions(
      document: document, rasterDocument: raster,
      languages: ["en-US"], recognizer: { _, _ in [] })
    let heading = try #require(native.first { $0.sourceText.contains("SOURCE HEADING") })
    let bounds = CGRect(
      x: heading.bounds.minX / 400, y: heading.bounds.minY / 320,
      width: heading.bounds.width / 400, height: heading.bounds.height / 320)
    let text = heading.sourceText
    let regions = try PDFLayoutTranslation.extractRegions(
      document: document, rasterDocument: raster,
      languages: ["en-US"],
      recognizer: { _, _ in
        [
          .init(text: text, normalizedBounds: bounds, confidence: 0.99),
          .init(
            text: text, normalizedBounds: CGRect(x: 0.45, y: 0.3, width: 0.4, height: 0.06),
            confidence: 0.99),
        ]
      })
    #expect(regions.filter { $0.kind == .imageOCR }.count == 1)
    #expect(regions.filter { $0.kind == .imageOCR }.first?.bounds.minY == 96)
  }

  @Test
  func layoutRefusesUnreadableTypeWithoutWritingAPartialResult() throws {
    let directory = try sampleDirectory("readability")
    defer { removeTemporary(directory) }
    let source = directory.appendingPathComponent("source.pdf")
    let output = directory.appendingPathComponent("overflow.pdf")
    try fixture(source)
    let region = PDFTranslationRegion(
      id: "tiny", pageIndex: 0, kind: .nativeText,
      bounds: CGRect(x: 80, y: 160, width: 100, height: 14), sourceText: "Label",
      preferredFontSize: 12)
    let report = try PDFLayoutTranslation.writeTranslatedPDF(
      inputURL: source, regions: [region],
      translations: [region.id: String(repeating: "译文", count: 20)], outputURL: output)
    #expect(report.overflowRegionIDs == [region.id])
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test
  func layoutRemapsInternalLinkDestinationsToOutputPages() throws {
    let directory = try sampleDirectory("internal-link")
    defer { removeTemporary(directory) }
    let source = directory.appendingPathComponent("source.pdf")
    let output = directory.appendingPathComponent("translated.pdf")
    try fixture(source)
    let original = try #require(PDFDocument(url: source))
    let first = try #require(original.page(at: 0))
    let second = try #require(first.copy() as? PDFPage)
    original.insert(second, at: 1)
    let link = PDFAnnotation(
      bounds: CGRect(x: 80, y: 180, width: 100, height: 20), forType: .link, withProperties: nil)
    link.action = PDFActionGoTo(
      destination: PDFDestination(page: second, at: CGPoint(x: 40, y: 200)))
    first.addAnnotation(link)
    #expect(original.write(to: source))
    _ = try PDFLayoutTranslation.writeTranslatedPDF(
      inputURL: source, regions: [], translations: [:], outputURL: output)
    let result = try #require(PDFDocument(url: output))
    let action = try #require(result.page(at: 0)?.annotations.first?.action as? PDFActionGoTo)
    let target = try #require(action.destination.page)
    #expect(result.index(for: target) == 1)
    #expect(action.destination.point == CGPoint(x: 40, y: 200))
  }

  @Test
  func markdownRendersHeadingsEmphasisTablesListsAndLinks() async throws {
    let directory = try sampleDirectory("markdown")
    defer { removeTemporary(directory) }
    let source = directory.appendingPathComponent("sample.md")
    let output = directory.appendingPathComponent("rendered.pdf")
    let markdown = """
      # Research report

      **Important** findings and [reference](https://example.org/reference).

      - First observation
      - Second observation

      | Metric | Value |
      | --- | ---: |
      | Sensitivity | 42 |
      | Specificity | 87 |

      ```swift
      let result = 42
      ```

      ![Local diagram](diagram.png)
      """
    try Data(markdown.utf8).write(to: source)
    _ = try await NativeDocumentProcessor.process(
      route: #require(NativeCapabilities.routes.first { $0.source == "md" && $0.target == "pdf" }),
      inputs: [source], options: JobOptions(), outputURL: output, apiKey: nil)
    let result = try #require(PDFDocument(url: output))
    let page = try #require(result.page(at: 0))
    let text = try #require(result.string)
    for literal in ["# Research", "**Important**", "| Metric", "```"] {
      #expect(!text.contains(literal))
    }
    for content in [
      "Research report", "Important", "Metric", "Sensitivity", "42", "let result", "Local diagram",
    ] {
      #expect(text.contains(content))
    }
    let title = try #require(
      result.findString("Research report", withOptions: []).first?.attributedString)
    let body = try #require(result.findString("findings", withOptions: []).first?.attributedString)
    let titleFont = try #require(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    let bodyFont = try #require(body.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(titleFont.pointSize > bodyFont.pointSize)
    let metric = try #require(result.findString("Metric", withOptions: []).first?.bounds(for: page))
    let value = try #require(result.findString("Value", withOptions: []).first?.bounds(for: page))
    #expect(value.minX > metric.maxX + 50)
    #expect(abs(value.midY - metric.midY) < 3)
    #expect(page.annotations.contains { $0.url?.absoluteString == "https://example.org/reference" })
  }

  @Test
  func markdownPaginatesLongTablesAndOversizedCellsWithoutLosingText() throws {
    let directory = try sampleDirectory("long-table")
    defer { removeTemporary(directory) }
    let output = directory.appendingPathComponent("rendered.pdf")
    let rows = (0..<100).map { "| Sample \($0) | Observation \($0) |" }.joined(separator: "\n")
    let longCell = String(repeating: "Long cell content. ", count: 500)
    try MarkdownPDFRenderer.write(
      "| Item | Detail |\n| --- | --- |\n\(rows)\n| Large row | \(longCell)ENDMARKER |", to: output)
    let result = try #require(PDFDocument(url: output))
    #expect(result.pageCount > 3)
    let text = try #require(result.string)
    #expect(text.contains("Sample 99"))
    #expect(text.contains("ENDMARKER"))
    let normalized = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    #expect(normalized.components(separatedBy: "Long cell content.").count - 1 == 500)
  }

  private func sampleDirectory(_ name: String) throws -> URL {
    let directory: URL
    if let root = ProcessInfo.processInfo.environment["TRANSALL_QUALITY_SAMPLES"] {
      directory = URL(fileURLWithPath: root).appendingPathComponent(name, isDirectory: true)
    } else {
      directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "transall-quality-\(UUID().uuidString)")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  @Test @MainActor
  func inspectionUsesSubmittedOriginalAndRejectsTamperedResultsWithoutLeavingCopies() async throws {
    let directory = try sampleDirectory("inspection")
    defer { removeTemporary(directory) }
    let input = directory.appendingPathComponent("source.pdf")
    try fixture(input)
    let submittedBytes = try Data(contentsOf: input)
    let storage = directory.appendingPathComponent("Storage", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: storage)
    await engine.start()
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let job = try await engine.createJob(
      route: route,
      files: [SelectedDocument(url: input, size: Int64(submittedBytes.count))],
      options: JobOptions())
    for _ in 0..<200 {
      if try engine.job(id: job.id).isFinished { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let finished = try engine.job(id: job.id)
    #expect(finished.status == "done")
    try Data("Original changed after submission".utf8).write(to: input)
    let snapshot = try await engine.inspectionSnapshot(jobID: job.id)
    let original = try #require(snapshot.original)
    #expect(try Data(contentsOf: original) == submittedBytes)
    #expect(PDFDocument(url: snapshot.result)?.pageCount == 1)
    try FileManager.default.removeItem(at: snapshot.directory)

    let jobDirectory = storage.appendingPathComponent("Jobs/\(job.id)", isDirectory: true)
    let output = jobDirectory.appendingPathComponent(try #require(finished.output))
    try Data("Tampered result".utf8).write(to: output)
    do {
      _ = try await engine.inspectionSnapshot(jobID: job.id)
      Issue.record("Inspection must validate the result receipt")
    } catch is NativeDocumentError {
      let names = try FileManager.default.contentsOfDirectory(atPath: jobDirectory.path)
      #expect(!names.contains { $0.hasPrefix("Inspection-") })
    }
    engine.prepareForTermination()
  }

  private func removeTemporary(_ directory: URL) {
    if ProcessInfo.processInfo.environment["TRANSALL_QUALITY_SAMPLES"] == nil {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  private func fixture(_ url: URL, mediaBox: CGRect = CGRect(x: 0, y: 0, width: 400, height: 320))
    throws
  {
    var box = mediaBox
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    context.beginPDFPage(nil)
    context.setFillColor(NSColor.white.cgColor)
    context.fill(box)
    for (text, point) in [
      ("SOURCE HEADING", CGPoint(x: 80, y: 270)), ("OUTSIDE CROP", CGPoint(x: 80, y: 45)),
    ] {
      context.textPosition = point
      CTLineDraw(
        CTLineCreateWithAttributedString(
          NSAttributedString(
            string: text,
            attributes: [
              .font: NSFont(name: "Helvetica", size: 14)!, .foregroundColor: NSColor.black,
            ])), context)
    }
    context.setFillColor(NSColor(calibratedRed: 0.2, green: 0.55, blue: 0.35, alpha: 1).cgColor)
    context.fill(CGRect(x: 310, y: 85, width: 40, height: 40))
    context.endPDFPage()
    context.closePDF()
  }
}
