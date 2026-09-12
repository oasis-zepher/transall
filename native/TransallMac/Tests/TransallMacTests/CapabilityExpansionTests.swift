import AppKit
import CryptoKit
import PDFKit
import Testing

@testable import TransallMac

@Suite(.serialized)
struct CapabilityExpansionTests {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "transall-capabilities-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func retain(_ url: URL, name: String) throws {
    guard let path = ProcessInfo.processInfo.environment["TRANSALL_CAPABILITY_ARTIFACTS"] else {
      return
    }
    let root = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data(contentsOf: url).write(to: root.appendingPathComponent(name), options: .atomic)
  }

  @Test func newRoutesStayWithinExistingTaskCategories() throws {
    #expect(NativeCapabilities.routes.count == 18)
    for source in ["word", "ppt", "excel"] {
      for target in ["pdf", "md"] {
        let selection = RouteSelection(source: source, target: target)
        #expect(
          WorkbenchTask.matching(selection) == (target == "pdf" ? .createPDF : .extractMarkdown))
        #expect(NativeCapabilities.routes.contains { $0.source == source && $0.target == target })
      }
    }
    let legacy = try JSONDecoder().decode(JobOptions.self, from: JSONEncoder().encode(JobOptions()))
    #expect(legacy.replaceFind == nil)
    var options = JobOptions()
    options.replaceFind = "old"
    options.replaceWith = "new"
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    #expect(options.canonicalized(for: route).replaceFind == "old")
  }

  @Test func csvPreservesQuotedDelimitersAndJSONRemainsCode() throws {
    let md = try DataMarkdown.document(
      "Name,Value\r\n\"A,B\",\"He said \"\"yes\"\"\"\r\n", extension: "csv")
    #expect(md.contains("| A,B | He said \"yes\" |"))
    #expect(throws: (any Error).self) {
      try DataMarkdown.document("\"unfinished", extension: "csv")
    }
    let json = try DataMarkdown.document("{\"alpha\":42}", extension: "json")
    #expect(json.contains("```json"))
    #expect(json.contains("42"))
  }

  @Test @MainActor func htmlExtractsStructureAndDoesNotExecuteScripts() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("source.html")
    let output = dir.appendingPathComponent("output.md")
    try
      "<h1>Heading</h1><p>Keep <strong>bold</strong>.</p><ul><li>First</li></ul><table><tr><th>A</th><th>B</th></tr><tr><td>42</td><td>99</td></tr></table><script>document.body.innerHTML='BAD_SCRIPT'</script>"
      .write(to: input, atomically: true, encoding: .utf8)
    try await WebDocumentConverter.convert(
      inputs: [input], source: "html", target: "md", output: output)
    let md = try String(contentsOf: output, encoding: .utf8)
    #expect(md.contains("# Heading"))
    #expect(md.contains("**bold**"))
    #expect(md.contains("- First"))
    #expect(md.contains("| 42 | 99 |"))
    #expect(!md.contains("BAD_SCRIPT"))
  }

  @Test @MainActor func styledHTMLPaginatesWithoutDroppingContent() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("source.html")
    let output = dir.appendingPathComponent("output.pdf")
    let content =
      "<style>h1{font-size:32px;color:#c00}</style><h1>First heading</h1>"
      + (0..<90).map { "<p>Paragraph \($0) retained content.</p>" }.joined() + "<p>Final marker</p>"
    try content.write(to: input, atomically: true, encoding: .utf8)
    try await WebDocumentConverter.convert(
      inputs: [input], source: "html", target: "pdf", output: output)
    let pdf = try #require(PDFDocument(url: output))
    try retain(output, name: "styled-html.pdf")
    #expect(pdf.pageCount > 1)
    #expect(pdf.string?.contains("Final marker") == true)
    #expect(pdf.findString("Paragraph 50 retained", withOptions: []).count == 1)
    #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).height == 842)
  }

  @Test(arguments: [0, 90, 180, 270])
  func replacementRemovesOldTextPreservesOtherSearchableTextAndGeometry(rotation: Int) throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = dir.appendingPathComponent("source.pdf")
    try MarkdownPDFRenderer.write(
      "# Alpha\n\nKeep this text. Replace CAT here.\n\nLast paragraph.", to: input)
    let originalBytes = try Data(contentsOf: input)
    let document = try #require(PDFDocument(url: input))
    document.page(at: 0)?.rotation = rotation
    try PDFTextReplacement.apply(to: document, find: "CAT", replacement: "DOG")
    let output = dir.appendingPathComponent("changed.pdf")
    #expect(document.write(to: output))
    try retain(output, name: "replacement-\(rotation).pdf")
    let result = try #require(PDFDocument(url: output))
    #expect(result.findString("CAT", withOptions: []).isEmpty)
    #expect(result.findString("DOG", withOptions: []).count == 1)
    #expect(result.string?.contains("Keep this text") == true)
    #expect(result.string?.contains("Last paragraph") == true)
    #expect(result.page(at: 0)?.rotation == rotation)
    #expect(try Data(contentsOf: input) == originalBytes)
    #expect(throws: (any Error).self) {
      try PDFTextReplacement.apply(to: result, find: "NO_SUCH_TEXT", replacement: "X")
    }
  }

  @Test(
    .enabled(if: OfficeDocumentConverter.executable != nil),
    arguments: ["docx", "doc", "pptx", "ppt", "xlsx", "xls"])
  func officeInputsProducePDFAndStructuredMarkdown(suffix: String) async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures")
    let input = fixtures.appendingPathComponent("sample.\(suffix)")
    let before = try Data(contentsOf: input)
    let source = suffix.hasPrefix("doc") ? "word" : suffix.hasPrefix("ppt") ? "ppt" : "excel"
    for target in ["pdf", "md"] {
      let output = dir.appendingPathComponent("output.\(target)")
      try await OfficeDocumentConverter.convert(
        inputs: [input], source: source, target: target, output: output)
      try retain(output, name: "\(suffix)-converted.\(target)")
      let text =
        target == "pdf"
        ? PDFDocument(url: output)?.string ?? "" : try String(contentsOf: output, encoding: .utf8)
      #expect(!text.contains("???"))
      #expect(!text.contains("0000/00/00"))
      #expect(text.contains("Alpha"))
      #expect(text.contains("42"))
      if source == "ppt" { #expect(text.contains("Last slide content")) }
      if source == "excel" { #expect(text.contains("Last sheet")) }
    }
    #expect(try Data(contentsOf: input) == before)
  }

  @Test(.enabled(if: OfficeDocumentConverter.executable != nil)) @MainActor
  func officeMarkdownSurvivesJobRecoveryAndVerifiedExport() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let input = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Fixtures/sample.docx")
    let engine = NativeDocumentEngine(dataDirectoryOverride: dir.appendingPathComponent("jobs"))
    await engine.start()
    defer { engine.prepareForTermination() }
    let route = try #require(
      NativeCapabilities.routes.first { $0.source == "word" && $0.target == "md" })
    let size = try input.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    let job = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: Int64(size))], options: JobOptions())
    for _ in 0..<400 {
      if try engine.job(id: job.id).isFinished { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    let finished = try engine.job(id: job.id)
    try #require(finished.status == "done", "\(finished.status): \(finished.error ?? "no error")")
    let recovered = NativeDocumentEngine(dataDirectoryOverride: dir.appendingPathComponent("jobs"))
    await recovered.start()
    defer { recovered.prepareForTermination() }
    #expect(try recovered.taskConfiguration(jobID: job.id).route.source == "word")
    let snapshot = try await recovered.inspectionSnapshot(jobID: job.id)
    defer { try? FileManager.default.removeItem(at: snapshot.directory) }
    let result = try #require(snapshot.result)
    #expect(result.pathExtension == "md")
    #expect(try String(contentsOf: result, encoding: .utf8).contains("Alpha"))
  }

  @Test @MainActor func embeddedImageIsPrintedAndTextRemainsSearchable() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
      ))
    let pixels = try #require(bitmap.bitmapData)
    for y in 0..<16 {
      for x in 0..<16 {
        let offset = y * bitmap.bytesPerRow + x * 4
        pixels[offset] = 255
        pixels[offset + 1] = 0
        pixels[offset + 2] = 0
        pixels[offset + 3] = 255
      }
    }
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    let input = dir.appendingPathComponent("image.md")
    let output = dir.appendingPathComponent("image.pdf")
    try
      "# Embedded image\n\n![Red square](data:image/png;base64,\(png.base64EncodedString()))\n\nEnd marker"
      .write(to: input, atomically: true, encoding: .utf8)
    try await WebDocumentConverter.convert(
      inputs: [input], source: "md", target: "pdf", output: output)
    try retain(output, name: "embedded-image.pdf")
    try retain(input, name: "embedded-image.md")
    let generatedHTML = try MarkdownHTML.document(String(contentsOf: input, encoding: .utf8))
    #expect(generatedHTML.contains("<img"))
    let pdf = try #require(PDFDocument(url: output))
    #expect(pdf.string?.contains("End marker") == true)
    let cg = try #require(CGPDFDocument(output as CFURL))
    let firstPage = try #require(cg.page(at: 1))
    let raster = try #require(
      NativeDocumentProcessor.render(page: firstPage, maximumDimension: 842))
    let rendered = NSBitmapImageRep(cgImage: raster)
    var hasRed = false
    for y in stride(from: 0, to: rendered.pixelsHigh, by: 2) {
      for x in stride(from: 0, to: rendered.pixelsWide, by: 2) {
        if let color = rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          color.redComponent > 0.8, color.greenComponent < 0.2, color.blueComponent < 0.2
        {
          hasRed = true
        }
      }
    }
    #expect(hasRed)
  }

  @Test func cancelledConverterTerminatesWithoutWaitingForTimeout() async throws {
    let dir = try directory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let start = Date()
    let task = Task {
      try await LocalConversionProcess.run(
        URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], directory: dir)
    }
    try await Task.sleep(for: .milliseconds(150))
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancellation must not return a result")
    } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    #expect(Date().timeIntervalSince(start) < 3)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
  }
}
