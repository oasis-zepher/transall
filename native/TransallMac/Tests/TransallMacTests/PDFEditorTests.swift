import AppKit
import Foundation
import PDFKit
import Testing

@testable import TransallMac

@Suite("Independent PDF editor")
@MainActor
struct PDFEditorTests {
  private func fixture() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("editor-source.pdf")
    try PDFDirectEditingTests().fixture().write(to: url)
    return url
  }

  @Test func inlineEditingUndoRedoSaveAndOriginalProtection() throws {
    let input = try fixture()
    defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
    let original = try Data(contentsOf: input)
    let model = PDFEditorModel()
    try model.load(input)
    let block = try #require(
      try model.blocks(page: 0).first(where: { $0.text.contains("Edit this text") }))
    try model.beginEditing(block: block, page: 0)
    #expect(model.document?.page(at: 0)?.string?.contains("Edit this text") == false)
    #expect(model.contentData == original)
    model.draft?.text = "Edited directly"
    #expect(model.hasPendingChanges)
    #expect(model.finishEditing())
    #expect(model.document?.page(at: 0)?.string?.contains("Edited directly") == true)
    #expect(model.canUndo && model.isDirty)
    model.undo()
    #expect(model.document?.page(at: 0)?.string?.contains("Edit this text") == true)
    #expect(model.canRedo && !model.isDirty)
    model.redo()
    #expect(model.document?.page(at: 0)?.string?.contains("Edited directly") == true)
    #expect(throws: (any Error).self) { try model.write(to: input) }
    let output = input.deletingLastPathComponent().appendingPathComponent("edited.pdf")
    try model.write(to: output)
    #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("Edited directly") == true)
    #expect(try Data(contentsOf: input) == original)
    #expect(!model.isDirty)
  }

  @Test func cancelAndSavePendingText() throws {
    let input = try fixture()
    defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
    let model = PDFEditorModel()
    #expect(model.receiveDroppedFiles([input]))
    let block = try #require(try model.blocks(page: 0).first)
    try model.beginEditing(block: block, page: 0)
    model.draft?.text = "Discard this"
    model.cancelEditing()
    #expect(model.document?.page(at: 0)?.string?.contains(block.text) == true)
    #expect(!model.isDirty && !model.canUndo)
    try model.beginEditing(block: block, page: 0)
    model.draft?.text = "Save pending text"
    model.draft?.width = 280
    let output = input.deletingLastPathComponent().appendingPathComponent("pending.pdf")
    try model.write(to: output)
    #expect(PDFDocument(url: output)?.page(at: 0)?.string?.contains("Save pending text") == true)
    #expect(model.draft == nil)
  }

  @Test func invalidEditKeepsDraftAndOriginalBytes() throws {
    let input = try fixture()
    defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
    let model = PDFEditorModel()
    try model.load(input)
    let original = model.contentData
    let block = try #require(try model.blocks(page: 0).first)
    try model.beginEditing(block: block, page: 0)
    model.draft?.fontSize = -2
    #expect(!model.finishEditing())
    #expect(model.error != nil && model.draft != nil)
    #expect(model.contentData == original && !model.canUndo)
  }

  @Test func nativeInlineInputUpdatesDraftAndSurvivesZoom() throws {
    let input = try fixture()
    defer { try? FileManager.default.removeItem(at: input.deletingLastPathComponent()) }
    let model = PDFEditorModel()
    try model.load(input)
    let view = DirectEditingPDFView(frame: CGRect(x: 0, y: 0, width: 700, height: 650))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 900, height: 750), styleMask: .borderless,
      backing: .buffered, defer: false)
    let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 750))
    window.contentView = container
    view.frame.origin = CGPoint(x: 80, y: 50)
    container.addSubview(view)
    view.editorModel = model
    model.attach(view)
    defer {
      view.stopMonitoring()
      model.detach()
    }
    model.synchronize(view)
    let block = try #require(try model.blocks(page: 0).first)
    view.layoutSubtreeIfNeeded()
    let page = try #require(model.document?.page(at: 0))
    let click = view.convert(CGPoint(x: block.bounds.midX, y: block.bounds.midY), from: page)
    let windowPoint = (view as NSView).convert(click, to: nil)
    let parentPoint = view.convert(windowPoint, from: nil as NSView?)
      .applying(CGAffineTransform(translationX: view.frame.minX, y: view.frame.minY))
    #expect(view.hitTest(parentPoint) === view)
    let event = try #require(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: windowPoint,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    view.mouseDown(with: event)
    #expect(model.draft?.block.text == block.text)
    #expect(model.error == nil)
    model.synchronize(view)
    view.layoutSubtreeIfNeeded()
    func inputView(_ view: NSView) -> NSTextView? {
      for child in view.subviews {
        if let text = child as? NSTextView { return text }
        if let text = inputView(child) { return text }
      }
      return nil
    }
    let textView = try #require(inputView(view))
    #expect(textView.string == block.text)
    textView.insertText(
      "In-page\n中文", replacementRange: NSRange(location: 0, length: textView.string.utf16.count))
    #expect(model.draft?.text == "In-page\n中文")
    let firstSize = try #require(textView.font?.pointSize)
    view.scaleFactor *= 1.25
    model.synchronize(view)
    #expect(abs((textView.font?.pointSize ?? 0) / firstSize - 1.25) < 0.01)
    #expect(model.draft?.text == "In-page\n中文")
    view.layoutSubtreeIfNeeded()
    let inputPoint = container.convert(CGPoint(x: 10, y: 10), from: textView)
    #expect(view.hitTest(inputPoint) === textView)
    if let directory = ProcessInfo.processInfo.environment["TRANSALL_EDITOR_REVIEW_DIR"],
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      try png.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent("native-inline-view.png"))
    }
    #expect(model.finishEditing())
    #expect(model.document?.page(at: 0)?.string?.contains("中文") == true)
    model.synchronize(view)
    #expect(inputView(view) == nil)
  }
}
