import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Security
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

  @Test
  func translationSessionDoesNotPersistProviderData() {
    let configuration = TranslationService.sessionConfiguration()

    #expect(configuration.identifier == nil)
    #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.urlCache == nil)
    #expect(configuration.httpCookieStorage == nil)
    #expect(!configuration.httpShouldSetCookies)
    #expect(configuration.urlCredentialStorage == nil)
  }

  @Test
  func pdfTranslationPolicyBoundsPaidWork() throws {
    try PDFTranslationPolicy.validate(pageCount: PDFTranslationPolicy.maximumPages)
    #expect(
      try PDFTranslationPolicy.totalCharacters(
        afterAdding: 1, to: PDFTranslationPolicy.maximumCharacters - 1)
        == PDFTranslationPolicy.maximumCharacters)

    do {
      try PDFTranslationPolicy.validate(pageCount: PDFTranslationPolicy.maximumPages + 1)
      Issue.record("Oversized PDF translation page counts should be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "processing_limit_exceeded")
      #expect(error.errorDescription?.contains("最多支持") == true)
      #expect(error.recoverySuggestion.contains("拆分 PDF"))
    }

    do {
      _ = try PDFTranslationPolicy.totalCharacters(
        afterAdding: 1, to: PDFTranslationPolicy.maximumCharacters)
      Issue.record("Oversized PDF translation text should be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "processing_limit_exceeded")
      #expect(error.errorDescription?.contains("待翻译字符") == true)
      #expect(error.recoverySuggestion.contains("删除不需要翻译的页面"))
    }
  }

  @Test @MainActor
  func importingDocumentsAppendsAndDeduplicatesFiles() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-import-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = temporary.appendingPathComponent("first.pdf")
    let second = temporary.appendingPathComponent("second.pdf")
    try Data("first".utf8).write(to: first)
    try Data("second".utf8).write(to: second)

    let model = AppModel()
    await model.importDocuments([first, first])
    await model.importDocuments([first, second, second], appending: true)

    #expect(model.documents.map(\.name) == ["first.pdf", "second.pdf"])
    #expect(model.documents.map(\.size) == [5, 6])
  }

  @Test @MainActor
  func importingDocumentsRejectsEntireBatchContainingSymbolicLink() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-import-link-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let existing = temporary.appendingPathComponent("existing.pdf")
    let valid = temporary.appendingPathComponent("valid.pdf")
    let symbolicLink = temporary.appendingPathComponent("linked.pdf")
    try Data("existing".utf8).write(to: existing)
    try Data("valid".utf8).write(to: valid)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: valid)

    let model = AppModel()
    await model.importDocuments([existing])
    await model.importDocuments([valid, symbolicLink])

    #expect(model.documents.map(\.name) == ["existing.pdf"])
    #expect(model.errorMessage?.contains("linked.pdf") == true)
    #expect(model.errorMessage?.contains("符号链接") == true)
    #expect(!model.isImporting)
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
  func invalidPDFEditOptionsAreRejectedBeforeTaskCreation() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-edit-preflight-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let input = temporary.appendingPathComponent("source.pdf")
    let files = [SelectedDocument(url: input, size: 4)]
    var options = JobOptions()
    options.deletePages = "1,,2"
    options.rotatePages = "1"
    options.rotateDegrees = 45
    options.cropPages = "1"
    options.cropBox = "0,0,0,20"

    let preflight = engine.preflight(route: route, files: files, options: options)
    #expect(!preflight.ok)
    #expect(preflight.blockingIssues.contains { $0.code == "invalid_page_selection" })
    #expect(preflight.blockingIssues.contains { $0.code == "invalid_rotation" })
    #expect(preflight.blockingIssues.contains { $0.code == "invalid_crop_box" })

    do {
      _ = try await engine.createJob(route: route, files: files, options: options)
      Issue.record("Invalid PDF edit options must be rejected before task creation")
    } catch {
      #expect(error.localizedDescription.contains("页码格式无效"))
    }

    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    let entries = try FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path)
    #expect(entries.isEmpty)

    options = JobOptions()
    options.editAction = "unknown"
    let invalidAction = engine.preflight(route: route, files: files, options: options)
    #expect(invalidAction.blockingIssues.contains { $0.code == "invalid_edit_action" })
  }

  @Test @MainActor
  func pdfEditOptionBoundsRejectOversizedAndNonfiniteValues() throws {
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let file = SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 4)
    var options = JobOptions()
    options.deletePages = String(
      repeating: "1", count: JobOptionValidator.maximumPageSelectionCharacters + 1)
    options.cropPages = "1"
    options.cropBox = "0,0,inf,20"
    options.watermark = String(
      repeating: "水", count: JobOptionValidator.maximumWatermarkCharacters + 1)

    let preflight = NativeDocumentEngine().preflight(
      route: route, files: [file], options: options)
    #expect(preflight.blockingIssues.contains { $0.code == "page_selection_too_large" })
    #expect(preflight.blockingIssues.contains { $0.code == "invalid_crop_box" })
    #expect(preflight.blockingIssues.contains { $0.code == "watermark_too_large" })

    options.deletePages = ""
    options.cropBox = String(
      repeating: "0", count: JobOptionValidator.maximumCropBoxCharacters + 1)
    options.watermark = ""
    let oversizedCrop = NativeDocumentEngine().preflight(
      route: route, files: [file], options: options)
    #expect(oversizedCrop.blockingIssues.contains { $0.code == "crop_box_too_large" })

    do {
      _ = try JobOptionValidator.parseCropBox("0,0,inf,20")
      Issue.record("Non-finite crop coordinates must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_option")
    }
  }

  @Test
  func jobOptionsCanonicalizationKeepsOnlyRouteFields() throws {
    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    let translationRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    var options = JobOptions()
    options.provider = "openai"
    options.outputMode = "bilingual"
    options.sourceLanguage = "fr"
    options.targetLanguage = "de"
    options.glossary = "private glossary marker"
    options.editAction = "merge"
    options.deletePages = "1"
    options.watermark = "private watermark marker"
    options.ocrLanguage = "fr-FR"
    options.ocrOutputFormat = "text"

    #expect(options.canonicalized(for: textRoute) == JobOptions())

    var expectedTranslation = JobOptions()
    expectedTranslation.provider = "openai"
    expectedTranslation.outputMode = "bilingual"
    expectedTranslation.sourceLanguage = "fr"
    expectedTranslation.targetLanguage = "de"
    expectedTranslation.glossary = "private glossary marker"
    expectedTranslation.ocrLanguage = "fr-FR"
    #expect(options.canonicalized(for: translationRoute) == expectedTranslation)
  }

  @Test @MainActor
  func translationAndOCROptionsAreRejectedBeforeProcessing() async throws {
    let store = TestCredentialStore(values: [.deepseek: "test-key"])
    let engine = NativeDocumentEngine(credentialStore: store)
    let translationRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let pdf = SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 4)
    var translation = JobOptions()
    translation.outputMode = "unknown"
    translation.sourceLanguage = "  "
    translation.targetLanguage = String(
      repeating: "x", count: JobOptionValidator.maximumLanguageCharacters + 1)
    translation.ocrLanguage = String(
      repeating: "y", count: JobOptionValidator.maximumOCRLanguageCharacters + 1)

    let translationPreflight = engine.preflight(
      route: translationRoute, files: [pdf], options: translation)
    #expect(
      translationPreflight.blockingIssues.contains {
        $0.code == "invalid_translation_output"
      })
    #expect(
      translationPreflight.blockingIssues.contains { $0.code == "invalid_source_language" })
    #expect(
      translationPreflight.blockingIssues.contains { $0.code == "invalid_target_language" })
    #expect(translationPreflight.blockingIssues.contains { $0.code == "invalid_ocr_language" })

    do {
      _ = try await NativeDocumentProcessor.process(
        route: translationRoute, inputs: [pdf.url], options: translation,
        outputURL: URL(fileURLWithPath: "/tmp/unused.pdf"), apiKey: "unused")
      Issue.record("Invalid translation options must fail before processing")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_option")
      #expect(error.errorDescription?.contains("翻译输出模式无效") == true)
    }

    let ocrRoute = try #require(NativeCapabilities.routes.first { $0.kind == "ocr" })
    var ocr = JobOptions()
    ocr.ocrOutputFormat = "unknown"
    ocr.ocrLanguage = String(
      repeating: "z", count: JobOptionValidator.maximumOCRLanguageCharacters + 1)
    let ocrPreflight = engine.preflight(route: ocrRoute, files: [pdf], options: ocr)
    #expect(ocrPreflight.blockingIssues.contains { $0.code == "invalid_ocr_output" })
    #expect(ocrPreflight.blockingIssues.contains { $0.code == "invalid_ocr_language" })
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

  @Test @MainActor
  func createJobRejectsUnregisteredRouteBeforeWritingTaskData() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-unsupported-route-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let input = temporary.appendingPathComponent("source.docx")
    try Data("not a supported native input".utf8).write(to: input, options: .atomic)
    let supported = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" && $0.source == "data" })
    let unsupported = RouteDefinition(
      source: "word", target: supported.target, kind: supported.kind, title: supported.title,
      enabled: true, accept: ".docx", input: "Word 文档", requirements: supported.requirements,
      optionPanels: supported.optionPanels, kindLabel: supported.kindLabel,
      output: supported.output, summary: supported.summary, engine: supported.engine,
      fallbackEngines: supported.fallbackEngines,
      dependencyProfile: supported.dependencyProfile, licenseNote: supported.licenseNote,
      ocrFallback: supported.ocrFallback)
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    defer { engine.prepareForTermination() }
    await engine.start()

    let preflight = engine.preflight(
      route: unsupported, files: [SelectedDocument(url: input, size: 28)],
      options: JobOptions())
    #expect(preflight.blockingIssues.map(\.code) == ["unsupported_route"])
    do {
      _ = try await engine.createJob(
        route: unsupported, files: [SelectedDocument(url: input, size: 28)],
        options: JobOptions())
      Issue.record("An unregistered native route must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_option")
      #expect(error.localizedDescription.contains("不属于当前原生版本"))
    }

    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path).isEmpty)
  }

  @Test @MainActor
  func createJobEnforcesStructuralPreflightBeforeWritingTaskData() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-create-preflight-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let text = temporary.appendingPathComponent("wrong.txt")
    let pdf = temporary.appendingPathComponent("single.pdf")
    try Data("wrong type".utf8).write(to: text, options: .atomic)
    try Data("single input".utf8).write(to: pdf, options: .atomic)
    let imageRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })
    let editRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    defer { engine.prepareForTermination() }
    await engine.start()

    do {
      _ = try await engine.createJob(route: imageRoute, files: [], options: JobOptions())
      Issue.record("An empty job must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_file")
      #expect(error.localizedDescription.contains("至少一个文件"))
    }

    do {
      _ = try await engine.createJob(
        route: imageRoute, files: [SelectedDocument(url: text, size: 10)],
        options: JobOptions())
      Issue.record("A mismatched input extension must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_file")
      #expect(error.localizedDescription.contains("输入格式"))
    }

    do {
      _ = try await engine.createJob(
        route: imageRoute,
        files: [
          SelectedDocument(url: text, size: Int64.max),
          SelectedDocument(url: text, size: Int64.max),
        ], options: JobOptions())
      Issue.record("Overflowing input sizes must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_file")
      #expect(error.localizedDescription.contains("250 MB"))
    }

    var mergeOptions = JobOptions()
    mergeOptions.editAction = "merge"
    do {
      _ = try await engine.createJob(
        route: editRoute, files: [SelectedDocument(url: pdf, size: 12)],
        options: mergeOptions)
      Issue.record("A one-file merge must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_option")
      #expect(error.localizedDescription.contains("至少需要两个文件"))
    }

    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path).isEmpty)
  }

  @Test @MainActor
  func textToPDFPreflightUsesMemorySafeInputLimit() throws {
    let engine = NativeDocumentEngine()
    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" && $0.source == "data" })
    let imageRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })
    let oversized = Int64(NativeCapabilities.textToPDFLimitBytes) + 1

    let textResult = engine.preflight(
      route: textRoute,
      files: [SelectedDocument(url: URL(fileURLWithPath: "/tmp/oversized.txt"), size: oversized)],
      options: JobOptions())
    let imageResult = engine.preflight(
      route: imageRoute,
      files: [SelectedDocument(url: URL(fileURLWithPath: "/tmp/oversized.png"), size: oversized)],
      options: JobOptions())

    #expect(!textResult.ok)
    #expect(textResult.blockingIssues.contains { $0.code == "upload_too_large" })
    #expect(
      textResult.blockingIssues.contains {
        $0.message.contains("\(NativeCapabilities.textToPDFLimitMB) MB")
      })
    #expect(imageResult.ok)
  }

  @Test @MainActor
  func credentialSettingsBlockWritesAfterKeychainLoadFailure() async {
    let store = TestCredentialStore(
      values: [.deepseek: "existing-deepseek", .openAI: "existing-openai"],
      readFailures: [.openAI])
    let settings = ProviderSettingsModel(store: store)
    let appModel = AppModel(backend: NativeDocumentEngine(credentialStore: store))

    #expect(!settings.isLoaded)
    #expect(settings.message.contains("现有 API Key 未被更改"))
    settings.deepseekKey = "replacement"
    await settings.save(appModel: appModel)

    #expect(store.values[.deepseek] == "existing-deepseek")
    #expect(store.values[.openAI] == "existing-openai")
    #expect(store.writes.isEmpty)
    #expect(settings.message.contains("先重新读取钥匙串"))
  }

  @Test @MainActor
  func credentialSettingsRollBackPartialSaveFailure() async {
    let store = TestCredentialStore(
      values: [.deepseek: "old-deepseek", .openAI: "old-openai"],
      writeFailures: [.openAI: 1])
    let settings = ProviderSettingsModel(store: store)
    let appModel = AppModel(backend: NativeDocumentEngine(credentialStore: store))
    settings.deepseekKey = "new-deepseek"
    settings.openAIKey = "new-openai"

    await settings.save(appModel: appModel)

    #expect(settings.isLoaded)
    #expect(settings.messageIsError)
    #expect(settings.message.contains("已验证钥匙串已恢复到保存前状态"))
    #expect(store.values[.deepseek] == "old-deepseek")
    #expect(store.values[.openAI] == "old-openai")
    #expect(store.writes.map(\.credential) == [.deepseek, .openAI, .deepseek])
  }

  @Test @MainActor
  func credentialSettingsRollBackWriteThatMutatesBeforeThrowing() async {
    let store = TestCredentialStore(
      values: [.deepseek: "old-deepseek", .openAI: "old-openai"],
      postWriteFailures: [.openAI: 1])
    let settings = ProviderSettingsModel(store: store)
    let appModel = AppModel(backend: NativeDocumentEngine(credentialStore: store))
    settings.deepseekKey = "new-deepseek"
    settings.openAIKey = "new-openai"

    await settings.save(appModel: appModel)

    #expect(settings.isLoaded)
    #expect(settings.messageIsError)
    #expect(settings.message.contains("已验证钥匙串已恢复到保存前状态"))
    #expect(settings.deepseekKey == "old-deepseek")
    #expect(settings.openAIKey == "old-openai")
    #expect(store.values[.deepseek] == "old-deepseek")
    #expect(store.values[.openAI] == "old-openai")
    #expect(store.writes.map(\.credential) == [.deepseek, .openAI, .openAI, .deepseek])
  }

  @Test @MainActor
  func credentialSettingsReconcilesRollbackFailureFromKeychainState() async {
    let store = TestCredentialStore(
      values: [.deepseek: "old-deepseek", .openAI: "old-openai"],
      writeFailureCalls: [.openAI: [2]], postWriteFailures: [.openAI: 1])
    let settings = ProviderSettingsModel(store: store)
    let appModel = AppModel(backend: NativeDocumentEngine(credentialStore: store))
    settings.deepseekKey = "new-deepseek"
    settings.openAIKey = "new-openai"

    await settings.save(appModel: appModel)

    #expect(settings.isLoaded)
    #expect(settings.messageIsError)
    #expect(settings.message.contains("OpenAI 未恢复到保存前状态"))
    #expect(settings.message.contains("已重新读取钥匙串当前值"))
    #expect(settings.deepseekKey == "old-deepseek")
    #expect(settings.openAIKey == "new-openai")
    #expect(store.values[.deepseek] == "old-deepseek")
    #expect(store.values[.openAI] == "new-openai")
    #expect(store.writes.map(\.credential) == [.deepseek, .openAI, .deepseek])
  }

  @Test @MainActor
  func credentialSettingsReconcilesDeletionThatMutatesBeforeThrowing() async {
    let store = TestCredentialStore(
      values: [.deepseek: "old-deepseek", .openAI: "old-openai"],
      postWriteFailures: [.deepseek: 1])
    let settings = ProviderSettingsModel(store: store)
    let appModel = AppModel(backend: NativeDocumentEngine(credentialStore: store))

    await settings.remove(.deepseek, appModel: appModel)

    #expect(settings.isLoaded)
    #expect(settings.messageIsError)
    #expect(settings.message.contains("实际已删除"))
    #expect(settings.deepseekKey.isEmpty)
    #expect(store.values[.deepseek]?.isEmpty == true)
  }

  @Test @MainActor
  func keychainMigratesLegacyCredentialsToLockedDataProtectionStorage() throws {
    let keychain = SimulatedKeychain()
    keychain.legacy[ProviderCredential.deepseek.rawValue] = Data("legacy-key".utf8)
    let store = ProviderCredentialStore(client: keychain.client)

    #expect(try store.value(for: .deepseek) == "legacy-key")
    #expect(keychain.legacy[ProviderCredential.deepseek.rawValue] == nil)
    #expect(
      keychain.protected[ProviderCredential.deepseek.rawValue] == Data("legacy-key".utf8))
    #expect(
      keychain.accessibility[ProviderCredential.deepseek.rawValue]
        == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String))

    try store.setValue("updated-key", for: .deepseek)
    #expect(
      keychain.protected[ProviderCredential.deepseek.rawValue] == Data("updated-key".utf8))
    try store.setValue("", for: .deepseek)
    #expect(keychain.protected[ProviderCredential.deepseek.rawValue] == nil)
  }

  @Test @MainActor
  func keychainRejectsMalformedCredentialData() {
    let keychain = SimulatedKeychain()
    keychain.protected[ProviderCredential.deepseek.rawValue] = Data([0xFF])
    let store = ProviderCredentialStore(client: keychain.client)

    do {
      _ = try store.value(for: .deepseek)
      Issue.record("Malformed Keychain data should not become an API key")
    } catch ProviderCredentialStoreError.keychain(let status) {
      #expect(status == errSecDecode)
    } catch {
      Issue.record("Unexpected error: \(error.localizedDescription)")
    }
  }

  @Test @MainActor
  func keychainFallsBackToLegacyStorageWithoutApplicationEntitlement() throws {
    let keychain = SimulatedKeychain(dataProtectionAvailable: false)
    keychain.legacy[ProviderCredential.openAI.rawValue] = Data("development-key".utf8)
    let store = ProviderCredentialStore(client: keychain.client)

    #expect(try store.value(for: .openAI) == "development-key")
    try store.setValue("replacement-key", for: .openAI)
    #expect(
      keychain.legacy[ProviderCredential.openAI.rawValue] == Data("replacement-key".utf8))
    #expect(keychain.protected[ProviderCredential.openAI.rawValue] == nil)

    try store.setValue("", for: .openAI)
    #expect(keychain.legacy[ProviderCredential.openAI.rawValue] == nil)
  }

  @Test @MainActor
  func preflightReportsKeychainReadFailureSeparatelyFromMissingKey() throws {
    let store = TestCredentialStore(readFailures: [.deepseek])
    let engine = NativeDocumentEngine(credentialStore: store)
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let file = SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 1)

    let result = engine.preflight(
      route: route, files: [file], options: JobOptions())

    #expect(result.blockingIssues.contains { $0.code == "provider_keychain_unavailable" })
    #expect(!result.blockingIssues.contains { $0.code == "provider_not_configured" })
  }

  @Test @MainActor
  func invalidTranslationProviderDoesNotReadAnyCredential() throws {
    let store = TestCredentialStore(readFailures: Set(ProviderCredential.allCases))
    let engine = NativeDocumentEngine(credentialStore: store)
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let file = SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 1)
    var options = JobOptions()
    options.provider = "unknown"

    let result = engine.preflight(route: route, files: [file], options: options)

    #expect(result.blockingIssues.contains { $0.code == "invalid_provider" })
    #expect(store.reads.isEmpty)
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

  @Test
  func resultSavingRejectsOriginalFileAndItsLinks() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-save-original-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let original = temporary.appendingPathComponent("original.pdf")
    let symbolicLink = temporary.appendingPathComponent("symbolic.pdf")
    let hardLink = temporary.appendingPathComponent("hard.pdf")
    try Data("original".utf8).write(to: original)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: original)
    try FileManager.default.linkItem(at: original, to: hardLink)
    let document = SelectedDocument(url: original, size: 8)

    for destination in [original, symbolicLink, hardLink] {
      do {
        try ResultSavePolicy.validate(
          destination: destination, originalDocuments: [document])
        Issue.record("Saving to an original file reference should be rejected")
      } catch let error as ResultSaveError {
        #expect(error.errorDescription?.contains("不能覆盖本次任务的原始文件") == true)
      }
    }
  }

  @Test
  func resultSavingAllowsNewAndUnrelatedDestinations() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-save-destination-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let original = temporary.appendingPathComponent("original.pdf")
    let existing = temporary.appendingPathComponent("existing.pdf")
    let newDestination = temporary.appendingPathComponent("new.pdf")
    try Data("original".utf8).write(to: original)
    try Data("existing".utf8).write(to: existing)
    let document = SelectedDocument(url: original, size: 8)

    try ResultSavePolicy.validate(
      destination: existing, originalDocuments: [document])
    try ResultSavePolicy.validate(
      destination: newDestination, originalDocuments: [document])
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
  func jobImportRejectsSymbolicLinkAndRemovesIncompleteDirectory() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-job-link-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let target = temporary.appendingPathComponent("target.png")
    let symbolicLink = temporary.appendingPathComponent("linked.png")
    try Data("target".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: target)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data"))
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    do {
      _ = try await engine.createJob(
        route: route, files: [SelectedDocument(url: symbolicLink, size: 1)],
        options: JobOptions())
      Issue.record("Symbolic-link input should fail before processing")
    } catch {
      #expect(error.localizedDescription.contains("普通文件"))
    }

    let jobsDirectory = temporary.appendingPathComponent("Data/Jobs")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path)
    #expect(remaining.isEmpty)
  }

  @Test @MainActor
  func jobImportRechecksActualCopiedSize() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-job-size-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let oversized = temporary.appendingPathComponent("oversized.png")
    #expect(FileManager.default.createFile(atPath: oversized.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(NativeCapabilities.uploadLimitBytes) + 1)
    try handle.close()

    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data"))
    await engine.start()
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    do {
      _ = try await engine.createJob(
        route: route, files: [SelectedDocument(url: oversized, size: 1)],
        options: JobOptions())
      Issue.record("Actual copied size should enforce the upload limit")
    } catch {
      #expect(error.localizedDescription.contains("250 MB"))
    }

    let jobsDirectory = temporary.appendingPathComponent("Data/Jobs")
    let remaining = try FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path)
    #expect(remaining.isEmpty)
  }

  @Test @MainActor
  func textJobImportRechecksRouteSpecificSizeLimit() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-text-job-size-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let oversized = temporary.appendingPathComponent("oversized.txt")
    #expect(FileManager.default.createFile(atPath: oversized.path, contents: nil))
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(NativeCapabilities.textToPDFLimitBytes) + 1)
    try handle.close()

    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data"))
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" && $0.source == "data" })

    do {
      _ = try await engine.createJob(
        route: route, files: [SelectedDocument(url: oversized, size: 1)],
        options: JobOptions())
      Issue.record("Actual copied size should enforce the text-to-PDF limit")
    } catch {
      #expect(
        error.localizedDescription.contains("\(NativeCapabilities.textToPDFLimitMB) MB"))
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
  func localJobDoesNotReadTranslationCredentials() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-local-keychain-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("input.png")
    try writeTestImage(to: input, color: CGColor(red: 0.3, green: 0.6, blue: 0.4, alpha: 1))
    let store = TestCredentialStore(readFailures: Set(ProviderCredential.allCases))
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data"), credentialStore: store)
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
    #expect(store.reads.isEmpty)
  }

  @Test @MainActor
  func localJobMetadataOmitsUnrelatedOptions() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-local-metadata-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("input.txt")
    let inputData = Data("local text".utf8)
    try inputData.write(to: input, options: .atomic)
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" && $0.source == "data" })
    var options = JobOptions()
    options.provider = "openai"
    options.glossary = "private glossary marker"
    options.watermark = "private watermark marker"
    options.ocrLanguage = "fr-FR"

    var job = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: Int64(inputData.count))],
      options: options)
    for _ in 0..<200 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try engine.job(id: job.id)
    }
    #expect(job.status == "done")

    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(job.id)", isDirectory: true)
    let metadataURL = jobDirectory.appendingPathComponent("metadata.json")
    let metadataData = try Data(contentsOf: metadataURL)
    let metadata = try JSONDecoder().decode(PersistedJobMetadata.self, from: metadataData)
    #expect(metadata.options == JobOptions())
    let metadataText = try #require(String(data: metadataData, encoding: .utf8))
    #expect(!metadataText.contains("private glossary marker"))
    #expect(!metadataText.contains("private watermark marker"))
  }

  @Test @MainActor
  func translationJobFailsClearlyWhenKeychainBecomesUnavailable() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-translation-keychain-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("source.pdf")
    try Data("not read because keychain fails first".utf8).write(to: input, options: .atomic)
    let store = TestCredentialStore(readFailures: [.deepseek])
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory, credentialStore: store)
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })

    var job = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: 1)], options: JobOptions())
    for _ in 0..<200 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try engine.job(id: job.id)
    }

    #expect(job.status == "failed")
    #expect(job.errorCode == "translation_provider_failed")
    #expect(job.error?.contains("钥匙串") == true)
    #expect(store.reads == [.deepseek])
    let directory = dataDirectory.appendingPathComponent("Jobs/\(job.id)", isDirectory: true)
    #expect(
      !FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("source-translated.pdf").path))
  }

  @Test @MainActor
  func processingStopsBeforeWorkWhenRunningStateCannotBeSaved() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-running-state-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("input.png")
    try writeTestImage(to: input, color: CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobPersister: { job, directory in
        if job.status == "running" { throw TestPersistenceError.unavailable }
        try persistTestJob(job, in: directory)
      })
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

    #expect(job.status == "failed")
    #expect(job.errorCode == "job_state_persistence_failed")
    #expect(job.errorHint?.contains("磁盘") == true)
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(job.id)", isDirectory: true)
    let persisted: JobResponse = try loadTestJSON("job.json", from: jobDirectory)
    #expect(persisted.status == "queued")
    #expect(
      !FileManager.default.fileExists(atPath: jobDirectory.appendingPathComponent("input.pdf").path)
    )
  }

  @Test @MainActor
  func processingFailureRemainsVisibleWhenFailureStateCannotBeSaved() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-failed-state-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("broken.png")
    try Data("not an image".utf8).write(to: input, options: .atomic)
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobPersister: { job, directory in
        if job.status == "failed" { throw TestPersistenceError.unavailable }
        try persistTestJob(job, in: directory)
      })
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

    #expect(job.status == "failed")
    #expect(job.errorCode == "job_state_persistence_failed")
    #expect(job.error?.contains("无法保存失败状态") == true)
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(job.id)", isDirectory: true)
    let persisted: JobResponse = try loadTestJSON("job.json", from: jobDirectory)
    #expect(persisted.status == "running")
  }

  @Test @MainActor
  func failedProcessingRemovesPartialOutput() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-failed-output-cleanup-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("source.png")
    try Data("processor fixture".utf8).write(to: input, options: .atomic)
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobProcessor: { _, _, _, outputURL, _ in
        try Data("partial result".utf8).write(to: outputURL, options: .atomic)
        throw NativeDocumentError.processing("测试处理失败")
      })
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    var job = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: 17)], options: JobOptions())
    for _ in 0..<200 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try engine.job(id: job.id)
    }

    let output = dataDirectory.appendingPathComponent("Jobs/\(job.id)/source.pdf")
    #expect(job.status == "failed")
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test @MainActor
  func cancelledProcessingRemovesPartialOutput() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-cancelled-output-cleanup-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let gate = DeletionRaceGate()
    let input = temporary.appendingPathComponent("source.png")
    try Data("processor fixture".utf8).write(to: input, options: .atomic)
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobProcessor: { _, _, _, outputURL, _ in
        try Data("partial result".utf8).write(to: outputURL, options: .atomic)
        await gate.markStarted()
        await withTaskCancellationHandler(
          operation: { await gate.waitForRelease() },
          onCancel: { Task { await gate.markCancelled() } })
        await gate.markFinished()
        try Task.checkCancellation()
        return NativeDocumentProcessor.Result(outputURL: outputURL, logs: [])
      })
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    let created = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: 17)], options: JobOptions())
    await gate.waitUntilStarted()
    let output = dataDirectory.appendingPathComponent("Jobs/\(created.id)/source.pdf")
    #expect(FileManager.default.fileExists(atPath: output.path))

    let cancelled = try engine.cancelJob(id: created.id)
    #expect(cancelled.status == "cancelled")
    await gate.waitUntilCancelled()
    await gate.release()
    await gate.waitUntilFinished()
    for _ in 0..<200 where FileManager.default.fileExists(atPath: output.path) {
      try await Task.sleep(for: .milliseconds(10))
    }

    #expect(try engine.job(id: created.id).status == "cancelled")
    #expect(!FileManager.default.fileExists(atPath: output.path))
  }

  @Test @MainActor
  func processingSuccessWithoutCompleteOutputFails() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-missing-output-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("source.png")
    try Data("processor fixture".utf8).write(to: input, options: .atomic)
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobProcessor: { _, _, _, outputURL, _ in
        NativeDocumentProcessor.Result(outputURL: outputURL, logs: [])
      })
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    var job = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: 17)], options: JobOptions())
    for _ in 0..<200 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try engine.job(id: job.id)
    }

    #expect(job.status == "failed")
    #expect(job.error?.contains("完整可用") == true)
    #expect(job.output == nil)
  }

  @Test @MainActor
  func processingSuccessFromUnexpectedLocationFailsAndCleansExpectedOutput() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-unexpected-output-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("source.png")
    try Data("processor fixture".utf8).write(to: input, options: .atomic)
    let unexpectedOutput = temporary.appendingPathComponent("unexpected.pdf")
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobProcessor: { _, _, _, outputURL, _ in
        try Data("partial result".utf8).write(to: outputURL, options: .atomic)
        try Data("external result".utf8).write(to: unexpectedOutput, options: .atomic)
        return NativeDocumentProcessor.Result(outputURL: unexpectedOutput, logs: [])
      })
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })

    var job = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: 17)], options: JobOptions())
    for _ in 0..<200 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try engine.job(id: job.id)
    }

    let expectedOutput = dataDirectory.appendingPathComponent("Jobs/\(job.id)/source.pdf")
    #expect(job.status == "failed")
    #expect(job.error?.contains("意外的结果位置") == true)
    #expect(!FileManager.default.fileExists(atPath: expectedOutput.path))
    #expect(FileManager.default.fileExists(atPath: unexpectedOutput.path))
  }

  @Test @MainActor
  func cancellationRemainsVisibleWhenCancelledStateCannotBeSaved() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-cancel-state-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("input.png")
    try writeTestImage(to: input, color: CGColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1))
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobPersister: { job, directory in
        if job.status == "cancelled" { throw TestPersistenceError.unavailable }
        try persistTestJob(job, in: directory)
      })
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })
    let inputs = (0..<20).map { _ in SelectedDocument(url: input, size: 1) }

    let created = try await engine.createJob(
      route: route, files: inputs, options: JobOptions())
    let cancelled = try engine.cancelJob(id: created.id)

    #expect(cancelled.status == "failed")
    #expect(cancelled.cancelRequested)
    #expect(cancelled.errorCode == "job_state_persistence_failed")
    #expect(cancelled.error?.contains("无法保存取消状态") == true)
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(created.id)", isDirectory: true)
    let persisted: JobResponse = try loadTestJSON("job.json", from: jobDirectory)
    #expect(["queued", "running"].contains(persisted.status))
  }

  @Test @MainActor
  func completedOutputRecoversWithoutRepeatingWorkWhenFinalStateCannotBeSaved() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-complete-state-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("input.png")
    try writeTestImage(to: input, color: CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobPersister: { job, directory in
        if job.status == "done" { throw TestPersistenceError.unavailable }
        try persistTestJob(job, in: directory)
      })
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
    #expect(job.logs.contains { $0.contains("完成状态未能保存") })
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(job.id)", isDirectory: true)
    let stale: JobResponse = try loadTestJSON("job.json", from: jobDirectory)
    #expect(stale.status == "running")
    #expect(
      FileManager.default.fileExists(
        atPath: jobDirectory.appendingPathComponent("completion.json").path)
    )
    let output = try #require(job.output)
    #expect(
      (try NativeDocumentProcessor.previewPageCount(
        pdfURL: jobDirectory.appendingPathComponent(output), limit: 1)) == 1)

    let restoredEngine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await restoredEngine.start()
    let restored = try restoredEngine.job(id: job.id)
    let persisted: JobResponse = try loadTestJSON("job.json", from: jobDirectory)

    #expect(restored.status == "done")
    #expect(restored.logs.contains { $0.contains("从完整结果恢复") })
    #expect(persisted.status == "done")
  }

  @Test @MainActor
  func interruptedTranslationIsNotAutomaticallyRetried() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-interrupted-translation-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().string(from: Date())
    let job = JobResponse(
      id: jobID, kind: route.kind, status: "running", inputs: ["source.pdf"],
      createdAt: now, updatedAt: now, output: nil, error: nil, stage: "processing",
      message: "原生引擎正在处理。", errorCode: nil, errorHint: nil, retryable: false,
      progress: 12, cancelRequested: false, logs: [])
    var options = JobOptions()
    options.provider = "openai"
    try persistTestJob(job, in: jobDirectory)
    try JSONEncoder().encode(
      PersistedJobMetadata(route: route, options: options, inputNames: ["1-source.pdf"])
    ).write(to: jobDirectory.appendingPathComponent("metadata.json"), options: .atomic)
    try Data("incomplete".utf8).write(
      to: jobDirectory.appendingPathComponent("source-translated.pdf"), options: .atomic)

    let restored = try engine.job(id: jobID)
    let persisted: JobResponse = try loadTestJSON("job.json", from: jobDirectory)

    #expect(restored.status == "failed")
    #expect(restored.errorCode == "task_interrupted")
    #expect(restored.error?.contains("没有自动重试") == true)
    #expect(persisted.status == "failed")
    #expect(engine.serviceLog.contains { $0.contains("未自动重新执行") })
  }

  @Test @MainActor
  func legacyCompletionReceiptWithoutFingerprintDoesNotRecoverTranslation() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-partial-translation-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let translationRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let sourceText = temporary.appendingPathComponent("partial.txt")
    try Data("only part of the intended result".utf8).write(to: sourceText, options: .atomic)
    let output = jobDirectory.appendingPathComponent("source-translated.pdf")
    _ = try await NativeDocumentProcessor.process(
      route: textRoute, inputs: [sourceText], options: JobOptions(), outputURL: output,
      apiKey: nil)
    #expect((try NativeDocumentProcessor.previewPageCount(pdfURL: output, limit: 1)) == 1)

    let now = ISO8601DateFormatter().string(from: Date())
    let running = JobResponse(
      id: jobID, kind: translationRoute.kind, status: "running", inputs: ["source.pdf"],
      createdAt: now, updatedAt: now, output: nil, error: nil, stage: "processing",
      message: "原生引擎正在处理。", errorCode: nil, errorHint: nil, retryable: false,
      progress: 12, cancelRequested: false, logs: [])
    var options = JobOptions()
    options.provider = "openai"
    try persistTestJob(running, in: jobDirectory)
    try JSONEncoder().encode(
      PersistedJobMetadata(
        route: translationRoute, options: options, inputNames: ["1-source.pdf"])
    ).write(to: jobDirectory.appendingPathComponent("metadata.json"), options: .atomic)
    try Data(#"{"output":"source-translated.pdf"}"#.utf8).write(
      to: jobDirectory.appendingPathComponent("completion.json"), options: .atomic)

    let restored = try engine.job(id: jobID)

    #expect(restored.status == "failed")
    #expect(restored.errorCode == "task_interrupted")
    #expect(restored.output == nil)
    #expect(FileManager.default.fileExists(atPath: output.path))
  }

  @Test @MainActor
  func replacedOutputDoesNotMatchCompletionReceiptAfterRestart() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-replaced-completion-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    let translationRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let sourceText = temporary.appendingPathComponent("source.txt")
    let sourcePDF = temporary.appendingPathComponent("source.pdf")
    try Data("original completed output".utf8).write(to: sourceText, options: .atomic)
    _ = try await NativeDocumentProcessor.process(
      route: textRoute, inputs: [sourceText], options: JobOptions(), outputURL: sourcePDF,
      apiKey: nil)
    let sourceSize = try #require(
      sourcePDF.resourceValues(forKeys: [.fileSizeKey]).fileSize)

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let credentialStore = TestCredentialStore(values: [.deepseek: "test-key"])
    let firstEngine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobPersister: { job, directory in
        if job.status == "done" { throw TestPersistenceError.unavailable }
        try persistTestJob(job, in: directory)
      }, credentialStore: credentialStore,
      jobProcessor: { _, _, _, outputURL, _ in
        try FileManager.default.copyItem(at: sourcePDF, to: outputURL)
        return NativeDocumentProcessor.Result(outputURL: outputURL, logs: [])
      })
    await firstEngine.start()

    var job = try await firstEngine.createJob(
      route: translationRoute,
      files: [SelectedDocument(url: sourcePDF, size: Int64(sourceSize))],
      options: JobOptions())
    for _ in 0..<200 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try firstEngine.job(id: job.id)
    }
    #expect(job.status == "done")
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(job.id)", isDirectory: true)
    let output = jobDirectory.appendingPathComponent("source-translated.pdf")
    #expect(FileManager.default.fileExists(atPath: output.path))
    #expect(
      FileManager.default.fileExists(
        atPath: jobDirectory.appendingPathComponent("completion.json").path))
    firstEngine.prepareForTermination()

    var replacement = try Data(contentsOf: output)
    let header = Data("%PDF-1.".utf8)
    let headerRange = try #require(replacement.range(of: header))
    let minorVersionIndex = headerRange.upperBound
    replacement[minorVersionIndex] = replacement[minorVersionIndex] == 0x34 ? 0x35 : 0x34
    try replacement.write(to: output, options: .atomic)
    #expect(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize == sourceSize)
    #expect(PDFDocument(url: output)?.pageCount == 1)

    let restoredEngine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory, credentialStore: credentialStore)
    defer { restoredEngine.prepareForTermination() }
    await restoredEngine.start()
    let restored = try restoredEngine.job(id: job.id)

    #expect(restored.status == "failed")
    #expect(restored.errorCode == "task_interrupted")
    #expect(restored.output == nil)
  }

  @Test @MainActor
  func interruptedLocalTaskStillResumesAutomatically() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-local-recovery-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    defer { engine.prepareForTermination() }
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    let inputDirectory = jobDirectory.appendingPathComponent("Input", isDirectory: true)
    try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
    try writeTestImage(
      to: inputDirectory.appendingPathComponent("1-input.png"),
      color: CGColor(red: 0.4, green: 0.2, blue: 0.7, alpha: 1))
    let now = ISO8601DateFormatter().string(from: Date())
    let running = JobResponse(
      id: jobID, kind: route.kind, status: "running", inputs: ["input.png"],
      createdAt: now, updatedAt: now, output: nil, error: nil, stage: "processing",
      message: "原生引擎正在处理。", errorCode: nil, errorHint: nil, retryable: false,
      progress: 12, cancelRequested: false, logs: [])
    try persistTestJob(running, in: jobDirectory)
    try JSONEncoder().encode(
      PersistedJobMetadata(route: route, options: JobOptions(), inputNames: ["1-input.png"])
    ).write(to: jobDirectory.appendingPathComponent("metadata.json"), options: .atomic)

    var restored = try engine.job(id: jobID)
    for _ in 0..<200 where !restored.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      restored = try engine.job(id: jobID)
    }

    #expect(restored.status == "done")
    #expect(restored.output == "input.pdf")
    #expect(engine.serviceLog.contains { $0.contains("恢复上次未完成的本地任务") })
  }

  @Test @MainActor
  func invalidPersistedConfigurationDoesNotResumeLocalWork() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-invalid-recovery-options-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().string(from: Date())
    let running = JobResponse(
      id: jobID, kind: route.kind, status: "running", inputs: ["source.pdf"],
      createdAt: now, updatedAt: now, output: nil, error: nil, stage: "processing",
      message: "原生引擎正在处理。", errorCode: nil, errorHint: nil, retryable: false,
      progress: 12, cancelRequested: false, logs: [])
    var options = JobOptions()
    options.editAction = "unknown"
    try persistTestJob(running, in: jobDirectory)
    try JSONEncoder().encode(
      PersistedJobMetadata(route: route, options: options, inputNames: ["1-source.pdf"])
    ).write(to: jobDirectory.appendingPathComponent("metadata.json"), options: .atomic)

    let restored = try engine.job(id: jobID)
    let persisted: JobResponse = try loadTestJSON("job.json", from: jobDirectory)

    #expect(restored.status == "failed")
    #expect(restored.errorCode == "job_state_corrupt")
    #expect(restored.error?.contains("PDF 操作无效") == true)
    #expect(restored.logs.contains { $0.contains("本地状态校验失败") })
    #expect(persisted.status == "failed")

    let mergeJobID = UUID().uuidString.lowercased()
    let mergeDirectory = dataDirectory.appendingPathComponent(
      "Jobs/\(mergeJobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: mergeDirectory, withIntermediateDirectories: true)
    let mergeJob = JobResponse(
      id: mergeJobID, kind: route.kind, status: "running", inputs: ["source.pdf"],
      createdAt: now, updatedAt: now, output: nil, error: nil, stage: "processing",
      message: "原生引擎正在处理。", errorCode: nil, errorHint: nil, retryable: false,
      progress: 12, cancelRequested: false, logs: [])
    var mergeOptions = JobOptions()
    mergeOptions.editAction = "merge"
    try persistTestJob(mergeJob, in: mergeDirectory)
    try JSONEncoder().encode(
      PersistedJobMetadata(
        route: route, options: mergeOptions, inputNames: ["1-source.pdf"])
    ).write(to: mergeDirectory.appendingPathComponent("metadata.json"), options: .atomic)

    let invalidMerge = try engine.job(id: mergeJobID)

    #expect(invalidMerge.status == "failed")
    #expect(invalidMerge.errorCode == "job_state_corrupt")
    #expect(invalidMerge.error?.contains("缺少输入文件") == true)
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
  func corruptResultPathCannotEscapeJobDirectory() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-result-boundary-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let secret = dataDirectory.appendingPathComponent("outside.txt")
    try Data("must stay private".utf8).write(to: secret, options: .atomic)
    let now = ISO8601DateFormatter().string(from: Date())
    let job = JobResponse(
      id: jobID, kind: "text_to_pdf", status: "done", inputs: ["source.txt"],
      createdAt: now, updatedAt: now, output: "../../outside.txt", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    try persistTestJob(job, in: jobDirectory)
    let destination = temporary.appendingPathComponent("exported.txt")

    do {
      try await engine.download(jobID: jobID, to: destination)
      Issue.record("A stored result path must not escape its job directory")
    } catch {
      #expect(error.localizedDescription.contains("文件名无效"))
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path))
    #expect(try String(contentsOf: secret, encoding: .utf8) == "must stay private")
  }

  @Test @MainActor
  func symbolicLinkResultCannotBeDownloaded() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-result-link-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    let secret = temporary.appendingPathComponent("outside.pdf")
    try Data("outside data".utf8).write(to: secret, options: .atomic)
    try FileManager.default.createSymbolicLink(
      at: jobDirectory.appendingPathComponent("result.pdf"), withDestinationURL: secret)
    let now = ISO8601DateFormatter().string(from: Date())
    let job = JobResponse(
      id: jobID, kind: "text_to_pdf", status: "done", inputs: ["source.txt"],
      createdAt: now, updatedAt: now, output: "result.pdf", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    try persistTestJob(job, in: jobDirectory)
    let destination = temporary.appendingPathComponent("exported.pdf")

    do {
      try await engine.download(jobID: jobID, to: destination)
      Issue.record("A symbolic-link result must not be downloaded")
    } catch {
      #expect(error.localizedDescription.contains("普通文件"))
    }

    #expect(!FileManager.default.fileExists(atPath: destination.path))
  }

  @Test @MainActor
  func corruptRecoveryInputPathCannotEscapeInputDirectory() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-input-boundary-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" && $0.source == "data" })
    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: jobDirectory.appendingPathComponent("Input", isDirectory: true),
      withIntermediateDirectories: true)
    let outside = dataDirectory.appendingPathComponent("Jobs/outside.txt")
    try Data("must not be processed".utf8).write(to: outside, options: .atomic)
    let now = ISO8601DateFormatter().string(from: Date())
    let running = JobResponse(
      id: jobID, kind: route.kind, status: "running", inputs: ["outside.txt"],
      createdAt: now, updatedAt: now, output: nil, error: nil, stage: "processing",
      message: "原生引擎正在处理。", errorCode: nil, errorHint: nil, retryable: false,
      progress: 12, cancelRequested: false, logs: [])
    try persistTestJob(running, in: jobDirectory)
    try JSONEncoder().encode(
      PersistedJobMetadata(
        route: route, options: JobOptions(), inputNames: ["../../outside.txt"])
    ).write(to: jobDirectory.appendingPathComponent("metadata.json"), options: .atomic)

    let restored = try engine.job(id: jobID)

    #expect(restored.status == "failed")
    #expect(restored.errorCode == "job_state_corrupt")
    #expect(restored.error?.contains("文件名无效") == true)
    #expect(restored.errorHint?.contains("删除") == true)
    #expect(
      !FileManager.default.fileExists(
        atPath: jobDirectory.appendingPathComponent("outside.pdf").path))

    try await engine.deleteJob(id: jobID)
    #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
  }

  @Test @MainActor
  func symbolicLinkJobDirectoryIsRejected() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-job-directory-link-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let jobID = UUID().uuidString.lowercased()
    let externalDirectory = temporary.appendingPathComponent("External", isDirectory: true)
    try FileManager.default.createDirectory(
      at: externalDirectory, withIntermediateDirectories: true)
    let now = ISO8601DateFormatter().string(from: Date())
    let job = JobResponse(
      id: jobID, kind: "text_to_pdf", status: "done", inputs: ["source.txt"],
      createdAt: now, updatedAt: now, output: "result.pdf", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    try persistTestJob(job, in: externalDirectory)
    try FileManager.default.createSymbolicLink(
      at: dataDirectory.appendingPathComponent("Jobs/\(jobID)"),
      withDestinationURL: externalDirectory)

    do {
      _ = try engine.job(id: jobID)
      Issue.record("A symbolic-link job directory must not be opened")
    } catch {
      #expect(error.localizedDescription.contains("不是有效目录"))
    }
  }

  @Test @MainActor
  func startupUsesTaskCreationTimeForRetentionCleanup() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-expired-job-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let jobsDirectory = temporary.appendingPathComponent("Data/Jobs", isDirectory: true)
    let expiredID = UUID().uuidString.lowercased()
    let recentID = UUID().uuidString.lowercased()
    let expired = jobsDirectory.appendingPathComponent(expiredID, isDirectory: true)
    let recent = jobsDirectory.appendingPathComponent(recentID, isDirectory: true)
    let orphan = jobsDirectory.appendingPathComponent("orphan", isDirectory: true)
    try FileManager.default.createDirectory(at: expired, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
    let now = Date()
    let formatter = ISO8601DateFormatter()
    let expiredJob = JobResponse(
      id: expiredID, kind: "text_to_pdf", status: "done", inputs: ["old.txt"],
      createdAt: formatter.string(from: now.addingTimeInterval(-25 * 60 * 60)),
      updatedAt: formatter.string(from: now), output: "old.pdf", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    let recentJob = JobResponse(
      id: recentID, kind: "text_to_pdf", status: "done", inputs: ["recent.txt"],
      createdAt: formatter.string(from: now.addingTimeInterval(-60 * 60)),
      updatedAt: formatter.string(from: now), output: "recent.pdf", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    try persistTestJob(expiredJob, in: expired)
    try persistTestJob(recentJob, in: recent)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-60 * 60)],
      ofItemAtPath: expired.path)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
      ofItemAtPath: recent.path)
    try FileManager.default.setAttributes(
      [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
      ofItemAtPath: orphan.path)

    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data", isDirectory: true))
    await engine.start()

    #expect(!FileManager.default.fileExists(atPath: expired.path))
    #expect(FileManager.default.fileExists(atPath: recent.path))
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(engine.state == .running)
  }

  @Test @MainActor
  func resettingRouteClearsDismissedJobRestoration() throws {
    let suiteName = "transall-reset-route-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }

    let jobID = UUID().uuidString.lowercased()
    preferences.set(jobID, forKey: "transall.native.lastJobId")
    let model = AppModel(
      backend: NativeDocumentEngine(), preferences: preferences)
    model.selection.source = "pdf"
    model.selection.target = "pdf"
    let now = ISO8601DateFormatter().string(from: Date())
    model.currentJob = JobResponse(
      id: jobID, kind: "pdf_edit", status: "done", inputs: ["source.pdf"],
      createdAt: now, updatedAt: now, output: "source-edited.pdf", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    model.previewPages = [PreviewPage(page: 1, url: "preview.png")]
    model.preflightWarnings = [
      PreflightIssue(code: "old_warning", dependency: nil, message: "旧警告", hint: nil)
    ]

    model.resetRoute(animated: false)

    #expect(model.selection == RouteSelection())
    #expect(model.currentJob == nil)
    #expect(model.previewPages.isEmpty)
    #expect(model.preflightWarnings.isEmpty)
    let reopenedPreferences = try #require(UserDefaults(suiteName: suiteName))
    #expect(reopenedPreferences.string(forKey: "transall.native.lastJobId") == nil)
  }

  @Test @MainActor
  func submittingJobLocksRouteAndInputChanges() async throws {
    let suiteName = "transall-submit-lock-test-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }

    let jobID = UUID().uuidString.lowercased()
    preferences.set(jobID, forKey: "transall.native.lastJobId")
    let model = AppModel(
      backend: NativeDocumentEngine(), preferences: preferences)
    model.selection.source = "pdf"
    model.selection.target = "pdf"
    let original = SelectedDocument(
      url: URL(fileURLWithPath: "/tmp/original.pdf"), size: 128)
    model.documents = [original]
    model.isSubmitting = true

    model.chooseFormat("image", animated: false)
    #expect(model.selection.source == "pdf")
    #expect(model.selection.target == "pdf")
    #expect(model.errorMessage == "正在创建任务，请稍后再更换路径。")

    model.resetRoute(animated: false)
    #expect(model.selection.source == "pdf")
    #expect(model.selection.target == "pdf")
    #expect(preferences.string(forKey: "transall.native.lastJobId") == jobID)
    #expect(model.errorMessage == "正在创建任务，请稍后再重选路径。")

    await model.importDocuments(
      [URL(fileURLWithPath: "/tmp/replacement.pdf")], appending: false)
    #expect(model.documents.map(\.id) == [original.id])
    #expect(model.errorMessage == "正在创建任务，请稍后再修改输入文件。")

    model.removeDocument(original)
    #expect(model.documents.map(\.id) == [original.id])
  }

  @Test @MainActor
  func runtimeCleanupRemovesExpiredCurrentJobButKeepsRunningWork() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-runtime-cleanup-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    await engine.start()
    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    let expiredID = UUID().uuidString.lowercased()
    let runningID = UUID().uuidString.lowercased()
    let expiredDirectory = jobsDirectory.appendingPathComponent(expiredID, isDirectory: true)
    let runningDirectory = jobsDirectory.appendingPathComponent(runningID, isDirectory: true)
    try FileManager.default.createDirectory(
      at: expiredDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: runningDirectory, withIntermediateDirectories: true)

    let now = Date()
    let createdAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-25 * 60 * 60))
    let expiredJob = JobResponse(
      id: expiredID, kind: "text_to_pdf", status: "done", inputs: ["old.txt"],
      createdAt: createdAt, updatedAt: createdAt, output: "old.pdf", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })
    let runningJob = JobResponse(
      id: runningID, kind: route.kind, status: "running", inputs: ["input.png"],
      createdAt: createdAt, updatedAt: createdAt, output: nil, error: nil,
      stage: "processing", message: "原生引擎正在处理。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 12, cancelRequested: false, logs: [])
    try persistTestJob(expiredJob, in: expiredDirectory)
    try persistTestJob(runningJob, in: runningDirectory)
    try JSONEncoder().encode(
      PersistedJobMetadata(route: route, options: JobOptions(), inputNames: ["1-input.png"])
    ).write(to: runningDirectory.appendingPathComponent("metadata.json"), options: .atomic)

    let lastJobKey = "transall.native.lastJobId"
    UserDefaults.standard.set(expiredID, forKey: lastJobKey)
    defer { UserDefaults.standard.removeObject(forKey: lastJobKey) }
    let model = AppModel(backend: engine)
    model.currentJob = expiredJob
    model.previewPages = [PreviewPage(page: 1, url: "preview.png")]
    model.previewError = "旧预览错误"
    model.preflightWarnings = [
      PreflightIssue(code: "old_warning", dependency: nil, message: "旧警告", hint: nil)
    ]

    await model.cleanupExpiredJobs(now: now)

    #expect(!FileManager.default.fileExists(atPath: expiredDirectory.path))
    #expect(FileManager.default.fileExists(atPath: runningDirectory.path))
    #expect(model.currentJob == nil)
    #expect(model.previewPages.isEmpty)
    #expect(model.previewError == nil)
    #expect(model.preflightWarnings.isEmpty)
    #expect(UserDefaults.standard.string(forKey: lastJobKey) == nil)
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

  @Test @MainActor
  func failedAndCancelledJobsCanDeleteTheirLocalData() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-finished-delete-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(dataDirectoryOverride: dataDirectory)
    defer { engine.prepareForTermination() }
    await engine.start()
    let model = AppModel(backend: engine)

    for status in ["failed", "cancelled"] {
      let jobID = UUID().uuidString.lowercased()
      let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
      try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
      let now = ISO8601DateFormatter().string(from: Date())
      let job = JobResponse(
        id: jobID, kind: "text_to_pdf", status: status, inputs: ["source.txt"],
        createdAt: now, updatedAt: now, output: nil,
        error: status == "failed" ? "测试处理失败" : nil, stage: status,
        message: status == "failed" ? "任务失败。" : "任务已取消。", errorCode: nil,
        errorHint: nil, retryable: status == "failed", progress: 20,
        cancelRequested: status == "cancelled", logs: [])
      try persistTestJob(job, in: jobDirectory)
      model.currentJob = job

      #expect(model.canDeleteCurrentJob)
      await model.deleteCurrentJob()

      #expect(model.currentJob == nil)
      #expect(!model.isDeletingJob)
      #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
    }
  }

  @Test @MainActor
  func deletingCancelledJobWaitsForProcessingToStop() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-cancel-delete-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let gate = DeletionRaceGate()
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      jobProcessor: { _, _, _, outputURL, _ in
        await gate.markStarted()
        await withTaskCancellationHandler(
          operation: { await gate.waitForRelease() },
          onCancel: { Task { await gate.markCancelled() } })
        try FileManager.default.createDirectory(
          at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("late result".utf8).write(to: outputURL, options: .atomic)
        await gate.markFinished()
        return NativeDocumentProcessor.Result(outputURL: outputURL, logs: [])
      })
    defer { engine.prepareForTermination() }
    await engine.start()

    let input = temporary.appendingPathComponent("source.png")
    try Data("processor fixture".utf8).write(to: input, options: .atomic)
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })
    let created = try await engine.createJob(
      route: route, files: [SelectedDocument(url: input, size: 17)], options: JobOptions())
    await gate.waitUntilStarted()

    let cancelled = try engine.cancelJob(id: created.id)
    #expect(cancelled.status == "cancelled")
    await gate.waitUntilCancelled()

    let releaseTask = Task {
      try? await Task.sleep(for: .milliseconds(40))
      await gate.release()
    }
    try await engine.deleteJob(id: created.id)
    _ = await releaseTask.result
    await gate.waitUntilFinished()

    let jobDirectory = dataDirectory.appendingPathComponent(
      "Jobs/\(created.id)", isDirectory: true)
    #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
  }

  @Test @MainActor
  func deletingJobWaitsForCancelledPreviewBeforeRemovingData() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-delete-preview-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let gate = DeletionRaceGate()
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      previewGenerator: { _, directory in
        await gate.markStarted()
        await withTaskCancellationHandler(
          operation: { await gate.waitForRelease() },
          onCancel: { Task { await gate.markCancelled() } })
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent("page-1.png")
        try Data("late preview".utf8).write(to: page, options: .atomic)
        return [page]
      })
    defer { engine.prepareForTermination() }
    await engine.start()

    let jobID = UUID().uuidString.lowercased()
    let jobDirectory = dataDirectory.appendingPathComponent("Jobs/\(jobID)", isDirectory: true)
    try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
    try Data("preview source".utf8).write(
      to: jobDirectory.appendingPathComponent("result.pdf"), options: .atomic)
    let now = ISO8601DateFormatter().string(from: Date())
    let job = JobResponse(
      id: jobID, kind: "text_to_pdf", status: "done", inputs: ["source.txt"],
      createdAt: now, updatedAt: now, output: "result.pdf", error: nil,
      stage: "complete", message: "任务完成。", errorCode: nil, errorHint: nil,
      retryable: false, progress: 100, cancelRequested: false, logs: [])
    try persistTestJob(job, in: jobDirectory)

    let previewTask = Task { try await engine.previewPages(jobID: jobID) }
    await gate.waitUntilStarted()
    let deletionTask = Task { try await engine.deleteJob(id: jobID) }
    await gate.waitUntilCancelled()
    #expect(FileManager.default.fileExists(atPath: jobDirectory.path))

    await gate.release()
    try await deletionTask.value
    do {
      _ = try await previewTask.value
      Issue.record("A preview cancelled for task deletion must not finish successfully")
    } catch is CancellationError {
      // Expected: deletion cancels the in-flight preview before removing the directory.
    }

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

  @Test
  func symbolicLinkPreviewCacheEntriesAreRegenerated() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-preview-link-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let image = temporary.appendingPathComponent("source.png")
    try writeTestImage(to: image, color: CGColor(red: 0.4, green: 0.6, blue: 0.2, alpha: 1))
    let pdf = temporary.appendingPathComponent("source.pdf")
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "image_to_pdf" })
    _ = try await NativeDocumentProcessor.process(
      route: route, inputs: [image], options: JobOptions(), outputURL: pdf, apiKey: nil)

    let externalDirectory = temporary.appendingPathComponent("External", isDirectory: true)
    try FileManager.default.createDirectory(
      at: externalDirectory, withIntermediateDirectories: true)
    let externalPage = externalDirectory.appendingPathComponent("page-1.png")
    try writeTestImage(
      to: externalPage, color: CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
    let externalData = try Data(contentsOf: externalPage)
    let previewDirectory = temporary.appendingPathComponent("Preview", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: previewDirectory, withDestinationURL: externalDirectory)

    var pages = try await PreviewCache.pages(pdfURL: pdf, directory: previewDirectory)
    var directoryValues = try previewDirectory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    #expect(directoryValues.isDirectory == true)
    try #require(directoryValues.isSymbolicLink != true)
    #expect(try Data(contentsOf: externalPage) == externalData)
    #expect(pages.count == 1)

    try FileManager.default.removeItem(at: pages[0])
    try FileManager.default.createSymbolicLink(at: pages[0], withDestinationURL: externalPage)
    pages = try await PreviewCache.pages(pdfURL: pdf, directory: previewDirectory)
    directoryValues = try previewDirectory.resourceValues(
      forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    let pageValues = try pages[0].resourceValues(
      forKeys: [.isRegularFileKey, .isSymbolicLinkKey])

    #expect(directoryValues.isSymbolicLink != true)
    #expect(pageValues.isRegularFile == true)
    #expect(pageValues.isSymbolicLink != true)
    #expect(NativeDocumentProcessor.isReadableImage(pages[0]))
    #expect(try Data(contentsOf: externalPage) == externalData)
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
  func pdfTranslationProcessorRejectsMultipleInputs() async throws {
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let inputs = [
      URL(fileURLWithPath: "/tmp/first.pdf"),
      URL(fileURLWithPath: "/tmp/second.pdf"),
    ]

    do {
      _ = try await NativeDocumentProcessor.process(
        route: route, inputs: inputs, options: JobOptions(),
        outputURL: URL(fileURLWithPath: "/tmp/unused.pdf"), apiKey: nil)
      Issue.record("PDF translation must reject multiple inputs at the processor boundary")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_file")
      #expect(error.errorDescription?.contains("只能使用一个文件") == true)
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
  func oversizedTextInputIsRejectedBeforeLoading() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-oversized-text-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let input = temporary.appendingPathComponent("oversized.txt")
    #expect(FileManager.default.createFile(atPath: input.path, contents: nil))
    let handle = try FileHandle(forWritingTo: input)
    try handle.truncate(atOffset: UInt64(NativeCapabilities.textToPDFLimitBytes) + 1)
    try handle.close()
    let output = temporary.appendingPathComponent("output.pdf")
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" && $0.source == "data" })

    do {
      _ = try await NativeDocumentProcessor.process(
        route: route, inputs: [input], options: JobOptions(), outputURL: output, apiKey: nil)
      Issue.record("Oversized text should be rejected before loading or rendering")
    } catch let error as NativeDocumentError {
      #expect(error.code == "invalid_file")
      #expect(error.localizedDescription.contains("\(NativeCapabilities.textToPDFLimitMB) MB"))
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
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
  func markdownExtractionPreservesPageAndDocumentOrder() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-markdown-stream-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    let editRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let markdownRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "extract_markdown" && $0.source == "pdf" })
    var pagePDFs: [URL] = []
    for (index, marker) in ["STREAM-FIRST", "STREAM-SECOND", "STREAM-THIRD"].enumerated() {
      let text = temporary.appendingPathComponent("stream-\(index + 1).txt")
      let pdf = temporary.appendingPathComponent("stream-\(index + 1).pdf")
      try Data(marker.utf8).write(to: text, options: .atomic)
      _ = try await NativeDocumentProcessor.process(
        route: textRoute, inputs: [text], options: JobOptions(), outputURL: pdf, apiKey: nil)
      pagePDFs.append(pdf)
    }

    var mergeOptions = JobOptions()
    mergeOptions.editAction = "merge"
    let twoPagePDF = temporary.appendingPathComponent("two-pages.pdf")
    _ = try await NativeDocumentProcessor.process(
      route: editRoute, inputs: Array(pagePDFs.prefix(2)), options: mergeOptions,
      outputURL: twoPagePDF, apiKey: nil)

    let output = temporary.appendingPathComponent("output.md")
    _ = try await NativeDocumentProcessor.process(
      route: markdownRoute, inputs: [twoPagePDF, pagePDFs[2]], options: JobOptions(),
      outputURL: output, apiKey: nil)

    let markdown = try String(contentsOf: output, encoding: .utf8)
    let first = try #require(markdown.range(of: "STREAM-FIRST"))
    let second = try #require(markdown.range(of: "STREAM-SECOND"))
    let third = try #require(markdown.range(of: "STREAM-THIRD"))
    #expect(first.lowerBound < second.lowerBound)
    #expect(second.lowerBound < third.lowerBound)
    #expect(markdown[first.upperBound..<second.lowerBound].contains("---"))
    #expect(!markdown[second.upperBound..<third.lowerBound].contains("---"))
  }

  @Test
  func ocrTextOutputPreservesPageBoundariesWhileStreaming() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-ocr-text-stream-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let first = temporary.appendingPathComponent("first.png")
    let second = temporary.appendingPathComponent("second.png")
    try writeTestImage(to: first, color: CGColor(gray: 1, alpha: 1))
    try writeTestImage(to: second, color: CGColor(gray: 0.95, alpha: 1))
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "ocr" && $0.source == "image" })
    var options = JobOptions()
    options.ocrLanguage = "en-US"
    options.ocrOutputFormat = "text"
    let output = temporary.appendingPathComponent("output.txt")

    _ = try await NativeDocumentProcessor.process(
      route: route, inputs: [first, second], options: options, outputURL: output, apiKey: nil)

    #expect(try String(contentsOf: output, encoding: .utf8) == "\n\n")
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
  func imageLoadingDownsamplesOversizedInput() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-downsample-test-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: temporary) }
    try writeTestImage(
      to: temporary, color: CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1),
      width: 1_200, height: 600)

    let decoded = try NativeDocumentProcessor.loadImage(temporary, maximumDimension: 300)

    #expect(decoded.width == 300)
    #expect(decoded.height == 150)
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
  func translationRejectsOversizedProviderResponse() async throws {
    let responses = TranslationResponseSequence([
      .http(
        status: 200, headers: [:],
        body: Data(repeating: 0x20, count: TranslationService.maximumResponseBytes + 1))
    ])
    let service = TranslationService(
      provider: "openai", apiKey: "test-key",
      requestSender: { try await responses.send($0) },
      sleeper: { await responses.record(delay: $0) })

    do {
      _ = try await service.translate("source", source: "en", target: "zh", glossary: "")
      Issue.record("Oversized provider responses should be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("响应内容超过") == true)
    }
    let snapshot = await responses.snapshot()
    #expect(snapshot.requestCount == 1)
    #expect(snapshot.delays.isEmpty)
  }

  @Test
  func translationRejectsPathologicallyExpandedContent() async throws {
    let source = "short source"
    let maximum = TranslationService.maximumTranslatedCharacters(for: source)
    let body = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": String(repeating: "译", count: maximum + 1)]]]
    ])
    let responses = TranslationResponseSequence([
      .http(status: 200, headers: [:], body: body)
    ])
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { try await responses.send($0) },
      sleeper: { await responses.record(delay: $0) })

    do {
      _ = try await service.translate(source, source: "en", target: "zh", glossary: "")
      Issue.record("Pathologically expanded translations should be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("译文异常过长") == true)
    }
    #expect(await responses.snapshot().requestCount == 1)
  }

  @Test
  func translationBoundsProviderErrorDetails() async throws {
    let providerMessage = String(repeating: "provider failure detail ", count: 200)
    let body = try JSONSerialization.data(withJSONObject: [
      "error": ["message": providerMessage]
    ])
    let responses = TranslationResponseSequence([
      .http(status: 400, headers: [:], body: body)
    ])
    let service = TranslationService(
      provider: "openai", apiKey: "test-key",
      requestSender: { try await responses.send($0) },
      sleeper: { await responses.record(delay: $0) })

    do {
      _ = try await service.translate("source", source: "en", target: "zh", glossary: "")
      Issue.record("Provider error details should remain bounded")
    } catch let error as NativeDocumentError {
      let message = try #require(error.errorDescription)
      #expect(message.hasSuffix("…"))
      #expect(message.count <= TranslationService.maximumProviderErrorCharacters + 20)
      #expect(!message.contains(providerMessage))
    }
    #expect(await responses.snapshot().requestCount == 1)
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
  func nativePDFEditReordersPagesWithoutLoss() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-reorder-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    let editRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    var pagePDFs: [URL] = []
    for (index, marker) in ["FIRST-PAGE-MARKER", "SECOND-PAGE-MARKER"].enumerated() {
      let text = temporary.appendingPathComponent("page-\(index + 1).txt")
      let pdf = temporary.appendingPathComponent("page-\(index + 1).pdf")
      try Data(marker.utf8).write(to: text, options: .atomic)
      _ = try await NativeDocumentProcessor.process(
        route: textRoute, inputs: [text], options: JobOptions(), outputURL: pdf, apiKey: nil)
      pagePDFs.append(pdf)
    }

    var mergeOptions = JobOptions()
    mergeOptions.editAction = "merge"
    let merged = temporary.appendingPathComponent("merged.pdf")
    _ = try await NativeDocumentProcessor.process(
      route: editRoute, inputs: pagePDFs, options: mergeOptions, outputURL: merged, apiKey: nil)

    var reorderOptions = JobOptions()
    reorderOptions.reorderPages = "2,1"
    let reordered = temporary.appendingPathComponent("reordered.pdf")
    _ = try await NativeDocumentProcessor.process(
      route: editRoute, inputs: [merged], options: reorderOptions, outputURL: reordered,
      apiKey: nil)

    let document = try #require(PDFDocument(url: reordered))
    #expect(document.pageCount == 2)
    #expect(document.page(at: 0)?.string?.contains("SECOND-PAGE-MARKER") == true)
    #expect(document.page(at: 1)?.string?.contains("FIRST-PAGE-MARKER") == true)
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
    let unchangedSource = try #require(PDFDocument(url: source))
    #expect(unchangedSource.pageCount == 2)
    #expect(unchangedSource.page(at: 0)?.rotation == 0)

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

  @Test
  func pdfEditProcessorRejectsInvalidInputCounts() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-edit-count-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    let editRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    var inputs: [URL] = []
    for index in 1...2 {
      let text = temporary.appendingPathComponent("source-\(index).txt")
      let pdf = temporary.appendingPathComponent("source-\(index).pdf")
      try Data("page \(index)".utf8).write(to: text, options: .atomic)
      _ = try await NativeDocumentProcessor.process(
        route: textRoute, inputs: [text], options: JobOptions(), outputURL: pdf, apiKey: nil)
      inputs.append(pdf)
    }

    do {
      _ = try await NativeDocumentProcessor.process(
        route: editRoute, inputs: inputs, options: JobOptions(),
        outputURL: temporary.appendingPathComponent("invalid-edit.pdf"), apiKey: nil)
      Issue.record("Single-document editing must reject multiple inputs")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("只能使用一个文件") == true)
    }

    var mergeOptions = JobOptions()
    mergeOptions.editAction = "merge"
    do {
      _ = try await NativeDocumentProcessor.process(
        route: editRoute, inputs: [inputs[0]], options: mergeOptions,
        outputURL: temporary.appendingPathComponent("invalid-merge.pdf"), apiKey: nil)
      Issue.record("PDF merging must reject a single input")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("至少需要两个文件") == true)
    }
  }

  private func writeTestImage(
    to url: URL, color: CGColor, width: Int = 32, height: Int = 24
  ) throws {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }
}

private actor DeletionRaceGate {
  private var started = false
  private var cancelled = false
  private var released = false
  private var finished = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
  private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

  func markStarted() {
    started = true
    for waiter in startWaiters { waiter.resume() }
    startWaiters.removeAll()
  }

  func waitUntilStarted() async {
    guard !started else { return }
    await withCheckedContinuation { startWaiters.append($0) }
  }

  func markCancelled() {
    cancelled = true
    for waiter in cancellationWaiters { waiter.resume() }
    cancellationWaiters.removeAll()
  }

  func waitUntilCancelled() async {
    guard !cancelled else { return }
    await withCheckedContinuation { cancellationWaiters.append($0) }
  }

  func waitForRelease() async {
    guard !released else { return }
    await withCheckedContinuation { releaseWaiters.append($0) }
  }

  func release() {
    released = true
    for waiter in releaseWaiters { waiter.resume() }
    releaseWaiters.removeAll()
  }

  func markFinished() {
    finished = true
    for waiter in finishWaiters { waiter.resume() }
    finishWaiters.removeAll()
  }

  func waitUntilFinished() async {
    guard !finished else { return }
    await withCheckedContinuation { finishWaiters.append($0) }
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

private enum TestPersistenceError: LocalizedError {
  case unavailable

  var errorDescription: String? { "测试写盘失败" }
}

private struct PersistedJobMetadata: Codable {
  let route: RouteDefinition
  let options: JobOptions
  let inputNames: [String]
}

private func persistTestJob(_ job: JobResponse, in directory: URL) throws {
  try JSONEncoder().encode(job).write(
    to: directory.appendingPathComponent("job.json"), options: .atomic)
}

private func loadTestJSON<T: Decodable>(_ name: String, from directory: URL) throws -> T {
  try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
}

private final class TestCredentialStore: ProviderCredentialStoring {
  struct Write: Equatable {
    let credential: ProviderCredential
    let value: String
  }

  var values: [ProviderCredential: String]
  private(set) var reads: [ProviderCredential] = []
  private(set) var writes: [Write] = []
  private var readFailures: Set<ProviderCredential>
  private var writeFailures: [ProviderCredential: Int]
  private var writeFailureCalls: [ProviderCredential: Set<Int>]
  private var postWriteFailures: [ProviderCredential: Int]
  private var writeAttempts: [ProviderCredential: Int] = [:]

  init(
    values: [ProviderCredential: String] = [:],
    readFailures: Set<ProviderCredential> = [],
    writeFailures: [ProviderCredential: Int] = [:],
    writeFailureCalls: [ProviderCredential: Set<Int>] = [:],
    postWriteFailures: [ProviderCredential: Int] = [:]
  ) {
    self.values = values
    self.readFailures = readFailures
    self.writeFailures = writeFailures
    self.writeFailureCalls = writeFailureCalls
    self.postWriteFailures = postWriteFailures
  }

  func value(for credential: ProviderCredential) throws -> String {
    reads.append(credential)
    if readFailures.contains(credential) { throw TestCredentialError.unavailable }
    return values[credential] ?? ""
  }

  func setValue(_ value: String, for credential: ProviderCredential) throws {
    let attempt = writeAttempts[credential, default: 0] + 1
    writeAttempts[credential] = attempt
    if writeFailureCalls[credential]?.contains(attempt) == true {
      throw TestCredentialError.unavailable
    }
    if let failures = writeFailures[credential], failures > 0 {
      writeFailures[credential] = failures - 1
      throw TestCredentialError.unavailable
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    values[credential] = trimmed
    writes.append(Write(credential: credential, value: trimmed))
    if let failures = postWriteFailures[credential], failures > 0 {
      postWriteFailures[credential] = failures - 1
      throw TestCredentialError.unavailable
    }
  }
}

private enum TestCredentialError: LocalizedError {
  case unavailable

  var errorDescription: String? { "测试钥匙串不可用" }
}

@MainActor
private final class SimulatedKeychain {
  var legacy: [String: Data] = [:]
  var protected: [String: Data] = [:]
  var accessibility: [String: String] = [:]
  let dataProtectionAvailable: Bool

  init(dataProtectionAvailable: Bool = true) {
    self.dataProtectionAvailable = dataProtectionAvailable
  }

  var client: KeychainClient {
    KeychainClient(
      copyMatching: { [self] query in
        guard let account = account(in: query) else { return (errSecParam, nil) }
        if isDataProtection(query), !dataProtectionAvailable {
          return (errSecMissingEntitlement, nil)
        }
        let values = isDataProtection(query) ? protected : legacy
        guard let data = values[account] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
      },
      update: { [self] query, attributes in
        guard let account = account(in: query), let data = valueData(in: attributes) else {
          return errSecParam
        }
        if isDataProtection(query), !dataProtectionAvailable { return errSecMissingEntitlement }
        if isDataProtection(query) {
          guard protected[account] != nil else { return errSecItemNotFound }
          protected[account] = data
          recordAccessibility(attributes, account: account)
        } else {
          guard legacy[account] != nil else { return errSecItemNotFound }
          legacy[account] = data
        }
        return errSecSuccess
      },
      add: { [self] item in
        guard let account = account(in: item), let data = valueData(in: item) else {
          return errSecParam
        }
        if isDataProtection(item), !dataProtectionAvailable { return errSecMissingEntitlement }
        if isDataProtection(item) {
          guard protected[account] == nil else { return errSecDuplicateItem }
          protected[account] = data
          recordAccessibility(item, account: account)
        } else {
          guard legacy[account] == nil else { return errSecDuplicateItem }
          legacy[account] = data
        }
        return errSecSuccess
      },
      delete: { [self] query in
        guard let account = account(in: query) else { return errSecParam }
        if isDataProtection(query), !dataProtectionAvailable { return errSecMissingEntitlement }
        if isDataProtection(query) {
          guard protected.removeValue(forKey: account) != nil else {
            return errSecItemNotFound
          }
          accessibility[account] = nil
        } else {
          guard legacy.removeValue(forKey: account) != nil else { return errSecItemNotFound }
        }
        return errSecSuccess
      })
  }

  private func isDataProtection(_ query: [String: Any]) -> Bool {
    query[kSecUseDataProtectionKeychain as String] as? Bool == true
  }

  private func account(in query: [String: Any]) -> String? {
    query[kSecAttrAccount as String] as? String
  }

  private func valueData(in attributes: [String: Any]) -> Data? {
    attributes[kSecValueData as String] as? Data
  }

  private func recordAccessibility(_ attributes: [String: Any], account: String) {
    accessibility[account] = attributes[kSecAttrAccessible as String] as? String
  }
}
