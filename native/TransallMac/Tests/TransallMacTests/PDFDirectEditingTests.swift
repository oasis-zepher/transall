import AppKit
import CoreText
import PDFKit
import Testing

@testable import TransallMac

@Suite("Direct PDF content editing")
@MainActor
struct PDFDirectEditingTests {
  func fixture() throws -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 400, height: 400)
    let consumer = try #require(CGDataConsumer(data: data))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
    for _ in 0..<2 {
      context.beginPDFPage(nil)
      context.setFillColor(NSColor.systemYellow.cgColor)
      context.fill(CGRect(x: 30, y: 240, width: 330, height: 100))
      context.setStrokeColor(NSColor.black.cgColor)
      context.stroke(CGRect(x: 30, y: 240, width: 330, height: 100))
      for (text, y) in [("Edit this text", 300.0), ("Keep this text", 260.0)] {
        context.textPosition = CGPoint(x: 50, y: y)
        CTLineDraw(
          CTLineCreateWithAttributedString(
            NSAttributedString(
              string: text,
              attributes: [
                .font: NSFont(name: "Helvetica", size: 18)!, .foregroundColor: NSColor.black,
              ])), context)
      }
      let imageContext = try #require(
        CGContext(
          data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
      imageContext.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
      imageContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
      let image = try #require(imageContext.makeImage())
      context.draw(image, in: CGRect(x: 300, y: 50, width: 40, height: 40))
      context.endPDFPage()
    }
    context.closePDF()
    let doc = try #require(PDFDocument(data: data as Data))
    doc.page(at: 0)?.addAnnotation(
      PDFAnnotation(
        bounds: CGRect(x: 340, y: 360, width: 20, height: 20), forType: .text, withProperties: nil))
    return try #require(doc.dataRepresentation())
  }

  @Test func editsAreSelectableVectorContentAndPreserveOtherObjects() throws {
    let input = try fixture()
    let blocks = try PDFContentEditor.blocks(in: input, page: 0)
    let block = try #require(blocks.first(where: { $0.text.contains("Edit this text") }))
    var draft = PDFTextDraft(block: block)
    draft.text = "Direct editing\n中文输入"
    draft.fontSize = 20
    draft.width = 260
    let output = try PDFContentEditor.apply(draft, to: input, page: 0)
    let doc = try #require(PDFDocument(data: output))
    #expect(doc.pageCount == 2)
    #expect(doc.page(at: 0)?.string?.contains("Edit this text") == false)
    #expect(doc.page(at: 0)?.string?.contains("Direct editing") == true)
    #expect(doc.page(at: 0)?.string?.contains("中文输入") == true)
    #expect(doc.page(at: 0)?.string?.contains("Keep this text") == true)
    #expect(doc.page(at: 1)?.string == PDFDocument(data: input)?.page(at: 1)?.string)
    // Some PDFKit versions save the note with a separate popup annotation.
    let inputAnnotations = PDFDocument(data: input)?.page(at: 0)?.annotations.count ?? 0
    #expect(inputAnnotations >= 1)
    #expect(doc.page(at: 0)?.annotations.count == inputAnnotations)
    let before = try PDFContentEditor.objectCounts(in: input, page: 0)
    let after = try PDFContentEditor.objectCounts(in: output, page: 0)
    #expect(before.images == 1 && after.images == before.images)
    #expect(after.paths == before.paths)
    // Background color must survive regeneration of an ICC-color-space page.
    let context = try #require(
      CGContext(
        data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 1600,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    doc.page(at: 0)?.draw(with: .mediaBox, to: context)
    let image = try #require(context.makeImage())
    let bitmap = NSBitmapImageRep(cgImage: image)
    let color = try #require(bitmap.colorAt(x: 40, y: 80)?.usingColorSpace(.sRGB))
    #expect(color.redComponent > 0.8 && color.greenComponent > 0.5 && color.blueComponent < 0.2)
    let edited = try PDFContentEditor.blocks(in: output, page: 0)
    #expect(edited.contains(where: { $0.text == "Direct editing\n中文输入" }))
    if let directory = ProcessInfo.processInfo.environment["TRANSALL_EDITOR_REVIEW_DIR"] {
      let folder = URL(fileURLWithPath: directory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try input.write(to: folder.appendingPathComponent("direct-before.pdf"))
      try output.write(to: folder.appendingPathComponent("direct-after.pdf"))
    }
  }

  @Test func deleteAndMovePreserveTextObjects() throws {
    let input = try fixture()
    let block = try #require(try PDFContentEditor.blocks(in: input, page: 0).first)
    var draft = PDFTextDraft(block: block)
    draft.x += 20
    let moved = try PDFContentEditor.apply(draft, to: input, page: 0)
    let result = try #require(
      try PDFContentEditor.blocks(in: moved, page: 0).first(where: { $0.text == block.text }))
    #expect(abs(result.origin.x - block.origin.x - 20) < 0.1)
    draft.text = ""
    let deleted = try PDFContentEditor.apply(draft, to: input, page: 0)
    #expect(PDFDocument(data: deleted)?.page(at: 0)?.string?.contains(block.text) == false)
  }
}
