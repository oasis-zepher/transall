import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

// Review-only probes. Compile with the current production sources; no provider calls.
@main
struct ReviewProbe {
  static func main() async throws {
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var findings: [String: Any] = [:]

    let plain = root.appendingPathComponent("plain-source.pdf")
    var box = CGRect(x: 0, y: 0, width: 320, height: 240)
    let context = CGContext(plain as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    context.setFillColor(NSColor.white.cgColor)
    context.fill(box)
    func draw(_ text: String, x: CGFloat, y: CGFloat) {
      let attributed = NSAttributedString(string: text, attributes: [
        .font: NSFont(name: "Helvetica", size: 12)!, .foregroundColor: NSColor.black,
      ])
      context.textPosition = CGPoint(x: x, y: y)
      CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    draw("Native heading", x: 40, y: 175)
    draw("OUTSIDE CROP", x: 40, y: 12)
    context.endPDFPage()
    context.closePDF()

    let geometrySource = root.appendingPathComponent("geometry-source.pdf")
    let geometry = PDFDocument(url: plain)!
    let originalPage = geometry.page(at: 0)!
    originalPage.rotation = 90
    originalPage.setBounds(CGRect(x: 20, y: 40, width: 270, height: 180), for: .cropBox)
    let link = PDFAnnotation(bounds: CGRect(x: 40, y: 168, width: 100, height: 20), forType: .link, withProperties: nil)
    link.url = URL(string: "https://example.org")!
    originalPage.addAnnotation(link)
    let note = PDFAnnotation(bounds: CGRect(x: 40, y: 95, width: 200, height: 30), forType: .freeText, withProperties: nil)
    note.contents = "ANNOTATION TEXT"
    note.font = NSFont.systemFont(ofSize: 14)
    originalPage.addAnnotation(note)
    precondition(geometry.write(to: geometrySource))
    let reread = PDFDocument(url: geometrySource)!
    let regions = try PDFLayoutTranslation.extractRegions(
      document: reread, rasterDocument: CGPDFDocument(geometrySource as CFURL)!,
      languages: ["en-US"], recognizer: { _, _ in [] })
    let geometryOutput = root.appendingPathComponent("geometry-output.pdf")
    let report = try PDFLayoutTranslation.writeTranslatedPDF(inputURL: geometrySource,
      regions: regions, translations: Dictionary(uniqueKeysWithValues: regions.map { ($0.id, "译文") }),
      outputURL: geometryOutput)
    let before = reread.page(at: 0)!
    let after = PDFDocument(url: geometryOutput)!.page(at: 0)!
    findings["geometry"] = [
      "rotationBefore": before.rotation, "rotationAfter": after.rotation,
      "cropBefore": NSStringFromRect(before.bounds(for: .cropBox)),
      "cropAfter": NSStringFromRect(after.bounds(for: .cropBox)),
      "annotationsBefore": before.annotations.count, "annotationsAfter": after.annotations.count,
      "overflowRegions": report.overflowRegionIDs,
      "extractableTextAfter": after.string ?? "",
    ]

    let nativeDocument = PDFDocument(url: plain)!
    let duplicateRegions = try PDFLayoutTranslation.extractRegions(
      document: nativeDocument, rasterDocument: CGPDFDocument(plain as CFURL)!,
      languages: ["en-US"], recognizer: { _, _ in [
        PDFLayoutTranslation.OCRObservation(text: "Native heading",
          normalizedBounds: CGRect(x: 0.55, y: 0.3, width: 0.3, height: 0.06), confidence: 0.99),
      ] })
    findings["disjointOCRDuplicate"] = [
      "suppliedOCRRegions": 1,
      "retainedOCRRegions": duplicateRegions.filter { $0.kind == .imageOCR }.count,
      "note": "Injected OCR result matches native text but is at a separate page position.",
    ]

    let tinyOutput = root.appendingPathComponent("tiny-text-output.pdf")
    let tinyRegion = PDFTranslationRegion(id: "tiny", pageIndex: 0, kind: .nativeText,
      bounds: CGRect(x: 40, y: 120, width: 100, height: 14),
      sourceText: "Short label", preferredFontSize: 12)
    let tinyReport = try PDFLayoutTranslation.writeTranslatedPDF(inputURL: plain,
      regions: [tinyRegion], translations: ["tiny": String(repeating: "译文", count: 20)], outputURL: tinyOutput)
    let tinyDocument = PDFDocument(url: tinyOutput)
    let attributed = tinyDocument?.page(at: 0)?.attributedString ?? NSAttributedString(string: "")
    var translatedFontSizes: [CGFloat] = []
    attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
      if attributed.attributedSubstring(from: range).string.contains("译"), let font = value as? NSFont {
        translatedFontSizes.append(font.pointSize)
      }
    }
    findings["readability"] = ["overflowRegions": tinyReport.overflowRegionIDs,
      "translatedFontSizes": translatedFontSizes]

    let markdown = root.appendingPathComponent("sample.md")
    try Data("# Report\n\n**Important**\n\n| Item | Value |\n| --- | --- |\n| A | 42 |\n".utf8).write(to: markdown)
    let markdownPDF = root.appendingPathComponent("markdown-output.pdf")
    _ = try await NativeDocumentProcessor.process(
      route: NativeCapabilities.routes.first { $0.source == "md" && $0.target == "pdf" }!,
      inputs: [markdown], options: JobOptions(), outputURL: markdownPDF, apiKey: nil)
    findings["markdownOutputText"] = PDFDocument(url: markdownPDF)!.string ?? ""

    let data = try JSONSerialization.data(withJSONObject: findings, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("probe-results.json"))
    print(String(data: data, encoding: .utf8)!)
  }
}
