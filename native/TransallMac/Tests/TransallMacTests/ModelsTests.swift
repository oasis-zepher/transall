import CoreGraphics
import Foundation
import ImageIO
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

  @Test @MainActor
  func preflightRejectsEmptyFilesBeforeProcessing() throws {
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let document = SelectedDocument(url: URL(fileURLWithPath: "/tmp/empty.pdf"), size: 0)
    let result = NativeDocumentEngine().preflight(
      route: route, files: [document], options: JobOptions())

    #expect(!result.ok)
    #expect(result.blockingIssues.contains { $0.code == "empty_file" })
  }

  @Test @MainActor
  func preflightRejectsMultipleFilesForSingleDocumentRoutes() throws {
    let editRoute = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let translateRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let files = [
      SelectedDocument(url: URL(fileURLWithPath: "/tmp/first.pdf"), size: 4),
      SelectedDocument(url: URL(fileURLWithPath: "/tmp/second.pdf"), size: 4),
    ]

    let engine = NativeDocumentEngine()
    let edit = engine.preflight(route: editRoute, files: files, options: JobOptions())
    let translate = engine.preflight(route: translateRoute, files: files, options: JobOptions())

    #expect(edit.blockingIssues.contains { $0.code == "single_file_required" })
    #expect(translate.blockingIssues.contains { $0.code == "single_file_required" })

    var mergeOptions = JobOptions()
    mergeOptions.editAction = "merge"
    let merge = engine.preflight(route: editRoute, files: files, options: mergeOptions)
    #expect(!merge.blockingIssues.contains { $0.code == "single_file_required" })
    #expect(!merge.blockingIssues.contains { $0.code == "merge_requires_files" })
  }

  @Test @MainActor
  func preflightRejectsOversizedTranslationGlossary() throws {
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    var options = JobOptions()
    options.glossary = String(
      repeating: "术", count: TranslationService.maximumGlossaryCharacters + 1)
    let file = SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 10)

    let result = NativeDocumentEngine().preflight(
      route: route, files: [file], options: options)

    #expect(result.blockingIssues.contains { $0.code == "glossary_too_large" })
  }

  @Test
  func resultSavingReplacesExistingFile() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-save-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let source = temporary.appendingPathComponent("source.pdf")
    let destination = temporary.appendingPathComponent("destination.pdf")
    try Data("new result".utf8).write(to: source)
    try Data("old result".utf8).write(to: destination)

    try AtomicResultSaver.copyReplacing(source: source, destination: destination)

    #expect(try String(contentsOf: destination, encoding: .utf8) == "new result")
    #expect(FileManager.default.fileExists(atPath: source.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
    #expect(!leftovers.contains { $0.hasPrefix(".transall-save-") })
  }

  @Test
  func failedResultSavingPreservesExistingFile() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-save-failure-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let missingSource = temporary.appendingPathComponent("missing.pdf")
    let destination = temporary.appendingPathComponent("destination.pdf")
    try Data("existing result".utf8).write(to: destination)

    #expect(throws: Error.self) {
      try AtomicResultSaver.copyReplacing(source: missingSource, destination: destination)
    }

    #expect(try String(contentsOf: destination, encoding: .utf8) == "existing result")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
    #expect(!leftovers.contains { $0.hasPrefix(".transall-save-") })
  }

  @Test @MainActor
  func failedImportRemovesIncompleteJobDirectory() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-job-failure-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let readable = temporary.appendingPathComponent("readable.png")
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    try Data("not needed for the copy test".utf8).write(to: readable)
    let missing = temporary.appendingPathComponent("missing.png")
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data"))
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    do {
      _ = try await engine.createJob(
        route: route,
        files: [
          SelectedDocument(url: readable, size: 1),
          SelectedDocument(url: missing, size: 1),
        ],
        options: JobOptions())
      Issue.record("Missing second input should fail the import")
    } catch {
      #expect(error.localizedDescription.contains("missing.png"))
    }

    let jobsDirectory = temporary.appendingPathComponent("Data/Jobs")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path)
    #expect(remaining.isEmpty)
  }

  @Test @MainActor
  func nativeJobImportsAndDownloadsResult() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-job-transfer-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("input.png")
    try writeTestImage(to: input, color: CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data"))
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    var job = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: 1)], options: JobOptions())
    for _ in 0..<200 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try engine.job(id: job.id)
    }

    #expect(job.status == "done")
    let destination = temporary.appendingPathComponent("saved.pdf")
    try await engine.download(jobID: job.id, to: destination)
    #expect(PDFDocument(url: destination)?.pageCount == 1)
  }

  @Test @MainActor
  func corruptJobMetadataCanStillBeDeleted() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-corrupt-job-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    try Data("not-json".utf8).write(to: jobDirectory.appendingPathComponent("job.json"))

    try await engine.deleteJob(id: jobID)

    #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
  }

  @Test @MainActor
  func startupRemovesOnlyExpiredJobDirectories() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-expired-job-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let jobsDirectory = temporary.appendingPathComponent("Data/Jobs", isDirectory: true)
    let expired = jobsDirectory.appendingPathComponent("expired", isDirectory: true)
    let recent = jobsDirectory.appendingPathComponent("recent", isDirectory: true)
    try FileManager.default.createDirectory(at: expired, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-25 * 60 * 60)],
      ofItemAtPath: expired.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-60 * 60)],
      ofItemAtPath: recent.path)

    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data", isDirectory: true))
    await engine.start()

    #expect(!FileManager.default.fileExists(atPath: expired.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(engine.state == .running)
  }

  @Test @MainActor
  func deletingCurrentJobClearsItsResultState() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-delete-state-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().string(from: Date())
    let job = JobResponse(
      id: jobID, kind: "text_to_pdf", status: "done", inputs: ["source.txt"],
      createdAt: now, updatedAt: now, output: "result.pdf", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    try JSONEncoder().encode(job).write(
      to: jobDirectory.appendingPathComponent("job.json"), options: .atomic)
    let model = AppModel(backend: engine)
    model.currentJob = job
    model.previewError = "旧预览错误"

    await model.deleteCurrentJob()

    #expect(model.currentJob == nil)
    #expect(model.previewError == nil)
    #expect(!model.isDeletingJob)
    #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
  }

  @Test
  func imageToPDFProcessesEveryInputPage() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-image-pdf-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = temporary.appendingPathComponent("first.png")
    let second = temporary.appendingPathComponent("second.png")
    try writeTestImage(to: first, color: CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    try writeTestImage(to: second, color: CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
    let output = temporary.appendingPathComponent("images.pdf")
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    _ = try await NativeDocumentProcessor.process(
      route: route, inputs: [first, second], options: JobOptions(), outputURL: output,
      apiKey: nil)

    let document = try #require(PDFDocument(url: output))
    #expect(document.pageCount == 2)
  }

  @Test
  func incompleteOrCorruptPreviewCacheIsRegenerated() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-preview-cache-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = temporary.appendingPathComponent("first.png")
    let second = temporary.appendingPathComponent("second.png")
    try writeTestImage(to: first, color: CGColor(red: 0.7, green: 0.2, blue: 0.2, alpha: 1))
    try writeTestImage(to: second, color: CGColor(red: 0.2, green: 0.3, blue: 0.7, alpha: 1))
    let pdf = temporary.appendingPathComponent("source.pdf")
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })
    _ = try await NativeDocumentProcessor.process(
      route: route, inputs: [first, second], options: JobOptions(), outputURL: pdf, apiKey: nil)

    let previewDirectory = temporary.appendingPathComponent("Preview", isDirectory: true)
    try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: previewDirectory.appendingPathComponent("page-1.png"))

    var pages = try await PreviewCache.pages(pdfURL: pdf, directory: previewDirectory)
    #expect(pages.map(\.lastPathComponent) == ["page-1.png", "page-2.png"])
    #expect(pages.allSatisfy(NativeDocumentProcessor.isReadableImage))

    try Data("broken again".utf8).write(to: pages[1], options: .atomic)
    pages = try await PreviewCache.pages(pdfURL: pdf, directory: previewDirectory)
    #expect(pages.count == 2)
    #expect(pages.allSatisfy(NativeDocumentProcessor.isReadableImage))
  }

  @Test @MainActor
  func previewFailureIsVisibleAndCanBeRetried() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-preview-error-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let output = jobDirectory.appendingPathComponent("result.pdf")
    try Data("broken pdf".utf8).write(to: output)
    let now = ISO8601DateFormatter().string(from: Date())
    let job = JobResponse(
      id: jobID, kind: "text_to_pdf", status: "done", inputs: ["source.txt"],
      createdAt: now, updatedAt: now, output: output.lastPathComponent, error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    try JSONEncoder().encode(job).write(
      to: jobDirectory.appendingPathComponent("job.json"), options: .atomic)
    let model = AppModel(backend: engine)
    model.currentJob = job

    await model.refreshPreview()

    #expect(model.previewPages.isEmpty)
    #expect(model.previewError?.contains("无法生成 PDF 预览") == true)
    #expect(!model.isLoadingPreview)

    try FileManager.default.removeItem(at: output)
    let text = temporary.appendingPathComponent("source.txt")
    try Data("preview recovered".utf8).write(to: text)
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    _ = try await NativeDocumentProcessor.process(
      route: route, inputs: [text], options: JobOptions(), outputURL: output, apiKey: nil)

    await model.refreshPreview()

    #expect(model.previewError == nil)
    #expect(model.previewPages.count == 1)
  }

  @Test
  func invalidTranslationProviderIsRejectedBeforeProcessing() async throws {
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    var options = JobOptions()
    options.provider = "unknown"

    do {
      _ = try await NativeDocumentProcessor.process(
        route: route, inputs: [URL(fileURLWithPath: "/tmp/missing.pdf")], options: options,
        outputURL: URL(fileURLWithPath: "/tmp/unused.pdf"), apiKey: "unused")
      Issue.record("Unknown translation providers should be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_option")
      #expect(error.errorDescription?.contains("翻译服务无效") == true)
    }
  }

  @Test
  func oversizedGlossaryIsRejectedBeforeTranslation() async throws {
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    var options = JobOptions()
    options.glossary = String(
      repeating: "A", count: TranslationService.maximumGlossaryCharacters + 1)

    do {
      _ = try await NativeDocumentProcessor.process(
        route: route, inputs: [URL(fileURLWithPath: "/tmp/missing.pdf")], options: options,
        outputURL: URL(fileURLWithPath: "/tmp/unused.pdf"), apiKey: "unused")
      Issue.record("Oversized glossary should be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_option")
      #expect(error.errorDescription?.contains("术语表") == true)
    }
  }

  @Test
  func multipleTextInputsProduceSearchablePDF() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-text-pdf-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = temporary.appendingPathComponent("first.txt")
    let second = temporary.appendingPathComponent("second.txt")
    try Data("first searchable block".utf8).write(to: first)
    try Data("second searchable block".utf8).write(to: second)
    let output = temporary.appendingPathComponent("text.pdf")
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" && $0.source == "data" })

    _ = try await NativeDocumentProcessor.process(
      route: route, inputs: [first, second], options: JobOptions(), outputURL: output,
      apiKey: nil)

    let document = try #require(PDFDocument(url: output))
    let text = document.string ?? ""
    #expect(text.contains("first searchable block"))
    #expect(text.contains("second searchable block"))
  }

  @Test
  func markdownExtractionRejectsInvalidPDFClearly() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-invalid-pdf-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let invalidPDF = temporary.appendingPathComponent("broken.pdf")
    try Data("not a pdf".utf8).write(to: invalidPDF)
    let output = temporary.appendingPathComponent("output.md")
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "extract_markdown" && $0.source == "pdf" })

    do {
      _ = try await NativeDocumentProcessor.process(
        route: route, inputs: [invalidPDF], options: JobOptions(), outputURL: output,
        apiKey: nil)
      Issue.record("Invalid PDF should not be treated as an image")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_file")
      #expect(error.errorDescription?.contains("无法打开 broken.pdf") == true)
    }
  }

  @Test
  func imageLoadingAppliesOrientationMetadata() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-orientation-test-\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: temporary) }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(
      CGContext(
        data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let sourceImage = try #require(context.makeImage())
    let destination = try #require(
      CGImageDestinationCreateWithURL(temporary as CFURL, "public.jpeg" as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, sourceImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))

    let decoded = try NativeDocumentProcessor.loadImage(temporary)
    #expect(decoded.width == 20)
    #expect(decoded.height == 40)
  }

  @Test
  func translationNetworkErrorsHaveActionableMessages() {
    let offline = TranslationService.providerError(
      for: URLError(.notConnectedToInternet))
    let timedOut = TranslationService.providerError(for: URLError(.timedOut))

    #expect(offline.errorDescription?.contains("没有网络") == true)
    #expect(timedOut.errorDescription?.contains("超时") == true)
    #expect(offline.code == "translation_provider_failed")
  }

  @Test
  func translationRetriesRateLimitUsingRetryAfter() async throws {
    let responses = TranslationResponseSequence([
      .http(
        status: 429, headers: ["Retry-After": "2"],
        body: Data(#"{"error":{"message":"busy"}}"#.utf8)),
      .http(
        status: 200, headers: [:],
        body: Data(#"{"choices":[{"message":{"content":"译文"}}]}"#.utf8)),
    ])
    let service = TranslationService(
      provider: "openai", apiKey: "test-key",
      requestSender: { try await responses.send($0) },
      sleeper: { await responses.record(delay: $0) })

    let translated = try await service.translate(
      "source", source: "en", target: "zh", glossary: "")
    let snapshot = await responses.snapshot()

    #expect(translated == "译文")
    #expect(snapshot.requestCount == 2)
    #expect(snapshot.delays == [2])
  }

  @Test
  func translationDoesNotRetryAuthenticationFailure() async throws {
    let responses = TranslationResponseSequence([
      .http(
        status: 401, headers: [:],
        body: Data(#"{"error":{"message":"invalid key"}}"#.utf8))
    ])
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { try await responses.send($0) },
      sleeper: { await responses.record(delay: $0) })

    do {
      _ = try await service.translate("source", source: "en", target: "zh", glossary: "")
      Issue.record("Authentication failures should not be retried")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("invalid key") == true)
    }
    let snapshot = await responses.snapshot()
    #expect(snapshot.requestCount == 1)
    #expect(snapshot.delays.isEmpty)
  }

  @Test
  func translationStopsAfterBoundedNetworkRetries() async throws {
    let responses = TranslationResponseSequence([
      .network(.timedOut), .network(.timedOut), .network(.timedOut),
    ])
    let service = TranslationService(
      provider: "openai", apiKey: "test-key",
      requestSender: { try await responses.send($0) },
      sleeper: { await responses.record(delay: $0) })

    do {
      _ = try await service.translate("source", source: "en", target: "zh", glossary: "")
      Issue.record("Repeated network timeouts should eventually fail")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("超时") == true)
      #expect(error.errorDescription?.contains("已重试 2 次") == true)
    }
    let snapshot = await responses.snapshot()
    #expect(snapshot.requestCount == TranslationService.maximumAttempts)
    #expect(snapshot.delays == [0.5, 1])
  }

  @Test
  func translationCancellationStopsRetryBackoff() async throws {
    let responses = TranslationResponseSequence([
      .http(
        status: 503, headers: [:],
        body: Data(#"{"error":{"message":"temporarily unavailable"}}"#.utf8))
    ])
    let service = TranslationService(
      provider: "openai", apiKey: "test-key",
      requestSender: { try await responses.send($0) },
      sleeper: {
        await responses.record(delay: $0)
        throw CancellationError()
      })

    do {
      _ = try await service.translate("source", source: "en", target: "zh", glossary: "")
      Issue.record("Cancellation should stop retry backoff")
    } catch is CancellationError {
      // Expected.
    }
    let snapshot = await responses.snapshot()
    #expect(snapshot.requestCount == 1)
    #expect(snapshot.delays == [0.5])
  }

  @Test
  func retryAfterHTTPDateIsParsed() throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    let now = try #require(formatter.date(from: "Wed, 21 Oct 2015 07:27:58 GMT"))

    #expect(
      TranslationService.retryAfterDelay("Wed, 21 Oct 2015 07:28:00 GMT", now: now) == 2)
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
    #expect(PDFDocument(url: source)?.pageCount == 2)

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

    var invalidReorder = JobOptions()
    invalidReorder.reorderPages = "1"
    do {
      _ = try await NativeDocumentProcessor.process(
        route: editRoute, inputs: [source], options: invalidReorder,
        outputURL: temporary.appendingPathComponent("invalid-reorder.pdf"), apiKey: nil)
      Issue.record("Incomplete page order should be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("每一页") == true)
    }
  }

  private func writeTestImage(to url: URL, color: CGColor) throws {
    let context = try #require(
      CGContext(
        data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    let image = try #require(context.makeImage())
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }
}

private actor TranslationResponseSequence {
  enum Outcome: Sendable {
    case http(status: Int, headers: [String: String], body: Data)
    case network(URLError.Code)
  }

  private var outcomes: [Outcome]
  private var requestCount = 0
  private var delays: [TimeInterval] = []

  init(_ outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  func send(_ request: URLRequest) throws -> (Data, URLResponse) {
    requestCount += 1
    guard !outcomes.isEmpty else { throw URLError(.unknown) }
    let outcome = outcomes.removeFirst()
    switch outcome {
    case .network(let code):
      throw URLError(code)
    case .http(let status, let headers, let body):
      guard let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
      else {
        throw URLError(.badServerResponse)
      }
      return (body, response)
    }
  }

  func record(delay: TimeInterval) {
    delays.append(delay)
  }

  func snapshot() -> (requestCount: Int, delays: [TimeInterval]) {
    (requestCount, delays)
  }
}
