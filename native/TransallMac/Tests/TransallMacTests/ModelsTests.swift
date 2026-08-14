import Foundation
import PDFKit
import Testing

@testable import TransallMac

struct ModelsTests {
  @Test
  func routeSelectionResetsAfterCompletedPair() {
    var selection = RouteSelection()
    selection.choose("word")
    selection.choose("pdf")
    #expect(selection.source == "word")
    #expect(selection.target == "pdf")

    selection.choose("image")
    #expect(selection.source == "image")
    #expect(selection.target == nil)
  }

  @Test
  func requirementDecodesBooleanAndGroupValues() throws {
    let decoder = JSONDecoder()
    let required = try decoder.decode(
      RouteRequirement.self, from: Data(#"{"name":"tesseract","required":true}"#.utf8))
    let grouped = try decoder.decode(
      RouteRequirement.self, from: Data(#"{"name":"markitdown","required":"one-of-markdown"}"#.utf8)
    )

    #expect(required.required == .required(true))
    #expect(grouped.required == .group("one-of-markdown"))
  }

  @Test
  func nativeRoutesDoNotRequireExternalExecutables() {
    let routes = NativeCapabilities.response.routes
    #expect(!routes.isEmpty)
    #expect(routes.allSatisfy { $0.enabled })
    #expect(
      routes.allSatisfy { route in
        !route.engine.localizedCaseInsensitiveContains("python")
          && !route.engine.localizedCaseInsensitiveContains("pymupdf")
          && !route.engine.localizedCaseInsensitiveContains("tesseract")
      })
    #expect(routes.contains { $0.source == "pdf" && $0.target == "pdf" })
    #expect(routes.contains { $0.source == "pdf" && $0.target == "ocr" })
  }

  @Test
  func pageSelectionParsesRangesAndRejectsOutOfBounds() throws {
    #expect(try PageSelectionParser.indexes("1, 3-5", pageCount: 5) == [0, 2, 3, 4])
    #expect(throws: NativeDocumentError.self) {
      try PageSelectionParser.indexes("6", pageCount: 5)
    }
  }

  @Test
  func translationChunksRespectRequestLimitAndPreserveText() {
    let source = String(repeating: "甲", count: 23) + "\n\n" + String(repeating: "乙", count: 9)
    let chunks = TranslationService.chunks(source, maximumCharacters: 10)
    #expect(chunks.count == 4)
    #expect(chunks.allSatisfy { $0.count <= 10 })
    #expect(chunks.joined().filter { !$0.isWhitespace } == source.filter { !$0.isWhitespace })
  }

  @Test @MainActor
  func importingDocumentsAppendsAndDeduplicatesFiles() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-import-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = temporary.appendingPathComponent("first.pdf")
    let second = temporary.appendingPathComponent("second.pdf")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)

    let model = AppModel()
    model.importDocuments([first, first])
    model.importDocuments([first, second, second], appending: true)

    #expect(model.documents.map(\.name) == ["first.pdf", "second.pdf"])
    #expect(model.documents.map(\.size) == [5, 6])
  }

  @Test
  func outputNamesAreRecognizableAndSafe() throws {
    let editRoute = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let ocrRoute = try #require(NativeCapabilities.routes.first { $0.kind == "ocr" })
    let translateRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })

    #expect(
      OutputFileNamer.name(
        for: editRoute, options: JobOptions(), inputNames: ["1-研究/报告?.pdf"])
        == "报告-edited.pdf")
    #expect(
      OutputFileNamer.name(
        for: ocrRoute, options: JobOptions(), inputNames: ["1-scan.pdf"])
        == "scan-ocr.pdf")
    #expect(
      OutputFileNamer.name(
        for: translateRoute, options: JobOptions(), inputNames: ["1-paper.pdf"])
        == "paper-translated.pdf")
  }

  @Test
  func nativePDFEditDeletesAndRotatesPages() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-native-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let firstPDF = temporary.appendingPathComponent("first.pdf")
    let secondPDF = temporary.appendingPathComponent("second.pdf")
    let source = temporary.appendingPathComponent("source.pdf")
    let text = temporary.appendingPathComponent("source.txt")
    let secondText = temporary.appendingPathComponent("second.txt")
    try Data("第一页".utf8).write(to: text)
    try Data("第二页".utf8).write(to: secondText)
    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    _ = try await NativeDocumentProcessor.process(
      route: textRoute, inputs: [text], options: JobOptions(), outputURL: firstPDF,
      apiKey: nil)
    _ = try await NativeDocumentProcessor.process(
      route: textRoute, inputs: [secondText], options: JobOptions(), outputURL: secondPDF,
      apiKey: nil)

    var mergeOptions = JobOptions()
    mergeOptions.editAction = "merge"
    let editRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    _ = try await NativeDocumentProcessor.process(
      route: editRoute, inputs: [firstPDF, secondPDF], options: mergeOptions, outputURL: source,
      apiKey: nil)

    var options = JobOptions()
    options.deletePages = "2"
    options.rotatePages = "1"
    options.rotateDegrees = 90
    let output = temporary.appendingPathComponent("edited.pdf")
    _ = try await NativeDocumentProcessor.process(
      route: editRoute, inputs: [source], options: options, outputURL: output, apiKey: nil)

    let document = try #require(PDFDocument(url: output))
    #expect(document.pageCount == 1)
    #expect(document.page(at: 0)?.rotation == 90)
  }
}
