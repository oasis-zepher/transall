import AppKit
import Testing
import UniformTypeIdentifiers

@testable import TransallMac

@Suite(.serialized)
@MainActor
struct FileDropTests {
  @Test func finderPasteboardAndItemProvidersKeepFileURLsAndOrder() async throws {
    let urls = [
      URL(fileURLWithPath: "/tmp/下载/first file.pdf"), URL(fileURLWithPath: "/tmp/second.pdf"),
    ]
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.writeObjects(urls.map { $0 as NSURL }))
    #expect(FileDropSupport.urls(from: pasteboard) == urls)
    let providers = urls.map { NSItemProvider(object: $0 as NSURL) }
    #expect(try await FileDropSupport.urls(from: providers) == urls)
  }

  @Test func emptyHourglassInfersRouteAndSubsequentDropAppends() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let first = folder.appendingPathComponent("first.pdf")
    let second = folder.appendingPathComponent("second.pdf")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    #expect(model.receiveDroppedDocuments([first]))
    try await finishImport(model)
    #expect(model.selection == RouteSelection(source: "pdf", target: "pdf"))
    #expect(model.documents.map(\.url) == [first])
    #expect(model.receiveDroppedDocuments([second]))
    try await finishImport(model)
    #expect(model.documents.map(\.url) == [first, second])
    #expect(model.receiveDroppedDocuments([first]))
    try await finishImport(model)
    #expect(model.documents.map(\.url) == [first, second])
    model.isSubmitting = true
    #expect(!model.receiveDroppedDocuments([first]))
    #expect(model.documents.count == 2)
  }

  @Test func unsupportedDropPreservesExistingRouteAndEditorDocument() throws {
    let model = AppModel()
    model.capabilities = NativeCapabilities.response
    model.selection = RouteSelection(source: "word", target: nil)
    #expect(!model.receiveDroppedDocuments([URL(fileURLWithPath: "/tmp/test.pdf")]))
    #expect(model.selection == RouteSelection(source: "word", target: nil))
    #expect(!model.receiveDroppedDocuments([URL(string: "https://example.com/file.pdf")!]))
    let editor = PDFEditorModel()
    #expect(!editor.receiveDroppedFiles([URL(fileURLWithPath: "/tmp/test.docx")]))
    #expect(
      !editor.receiveDroppedFiles([
        URL(fileURLWithPath: "/tmp/one.pdf"), URL(fileURLWithPath: "/tmp/two.pdf"),
      ]))
    #expect(editor.document == nil)
  }

  private func finishImport(_ model: AppModel) async throws {
    for _ in 0..<200 {
      if !model.isImporting { break }
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(!model.isImporting)
    #expect(model.errorMessage == nil)
  }
}
