import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import LocalAuthentication
import PDFKit
import Security
import SwiftUI
import Testing

@testable import TransallMac

@Suite(.serialized)
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
  func privacyPolicyConfigurationAcceptsPublicHTTPSDestination() throws {
    let url = try #require(
      PrivacyPolicyConfiguration.url(from: "https://www.apple.com/legal/privacy/"))

    #expect(url.absoluteString == "https://www.apple.com/legal/privacy/")
  }

  @Test
  func privacyPolicyConfigurationRejectsMissingUnsafeAndNonPublicValues() {
    let invalidValues: [Any?] = [
      nil,
      42,
      "",
      " https://privacy.example.org/transall",
      "$(TRANSALL_PRIVACY_POLICY_URL)",
      "http://privacy.example.org/transall",
      "https://user:secret@privacy.example.org/transall",
      "https://localhost/privacy",
      "https://transall.local/privacy",
      "https://transall.example/privacy",
      "https://privacy.example.org/transall",
      "https://privacy.example.org:70000/transall",
      "https://privacy..example.org/transall",
      "https://-privacy.example.org/transall",
      "https://127.0.0.1/privacy",
      "https://privacy.example.org%2Fevil.invalid/transall",
    ]

    for value in invalidValues {
      #expect(PrivacyPolicyConfiguration.url(from: value) == nil)
    }
  }

  @Test @MainActor
  func appStartInitializesSharedStateOnlyOnce() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let suiteName = "TransallTests.Start.\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let store = TestCredentialStore(
      values: [.deepseek: "deepseek-key", .openAI: "openai-key"])
    let model = AppModel(
      backend: NativeDocumentEngine(
        dataDirectoryOverride: temporary, credentialStore: store),
      preferences: preferences)
    defer { model.prepareForTermination() }

    async let firstStart: Void = model.start()
    async let overlappingStart: Void = model.start()
    _ = await (firstStart, overlappingStart)
    await model.start()

    #expect(store.reads == ProviderCredential.allCases)
    #expect(model.providers.allSatisfy { $0.configured })
    #expect(model.backend.serviceLog.count { $0.contains("已就绪") } == 1)
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
  func translationRegionBatchesPreserveStableOrder() {
    let regions = (1...4).map { number in
      PDFTranslationRegion(
        id: String(format: "p0001-t%04d", number), pageIndex: 0, kind: .nativeText,
        bounds: CGRect(x: 10, y: number * 20, width: 100, height: 14),
        sourceText: String(repeating: "x", count: 24), preferredFontSize: 10)
    }

    let batches = TranslationService.regionBatches(regions)

    #expect(batches.count == 4)
    #expect(batches.flatMap { $0.map(\.id) } == regions.map(\.id))
  }

  @Test
  func translationRegionCheckpointsSurviveMalformedResponseAndSkipPaidWorkOnRetry() async throws {
    let records = RegionConcurrencyRecorder()
    let regions = (1...2).map { index in
      PDFTranslationRegion(
        id: "r\(index)", pageIndex: 0, kind: .nativeText,
        bounds: CGRect(x: 0, y: index * 20, width: 100, height: 14), sourceText: "Source \(index)",
        preferredFontSize: 10)
    }
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { request in
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        let content = body.contains("r1") ? "{\"id\":\"r1\",\"text\":\"第一\"}" : "{}"
        let data = try JSONSerialization.data(withJSONObject: [
          "choices": [["message": ["content": content]]]
        ])
        return (
          data,
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      })
    await #expect(throws: (any Error).self) {
      try await service.translateRegions(
        regions, source: "en", target: "zh", glossary: "", checkpoint: { await records.save($0) })
    }
    let saved = try #require(await records.checkpoints.last)
    #expect(saved == ["r1": "第一"])
    let retry = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { request in
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(!body.contains("r1"))
        #expect(body.contains("r2"))
        let data = try JSONSerialization.data(withJSONObject: [
          "choices": [["message": ["content": "{\"id\":\"r2\",\"text\":\"第二\"}"]]]
        ])
        return (
          data,
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      })
    let completed = try await retry.translateRegions(
      regions, source: "en", target: "zh", glossary: "", existingTranslations: saved)
    #expect(completed == ["r1": "第一", "r2": "第二"])
  }

  @Test
  func translationRegionConcurrencyKeepsOutOfOrderResponsesAttachedToSources() async throws {
    let calls = RegionConcurrencyRecorder()
    var regions = (1...9).map { index in
      PDFTranslationRegion(
        id: "region-\(index)", pageIndex: index / 3, kind: .nativeText,
        bounds: CGRect(x: 0, y: index * 20, width: 100, height: 14),
        sourceText: "Source \(index)", preferredFontSize: 10)
    }
    regions.append(
      PDFTranslationRegion(
        id: "stamp", pageIndex: 0, kind: .nativeText,
        bounds: CGRect(x: 0, y: 0, width: 200, height: 180), sourceText: "ARTICLE IN PRESS",
        preferredFontSize: 30, preserveOriginal: true))
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: 4,
      requestSender: { request in
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: String]])
        let content = try #require(messages.last?["content"]?.data(using: .utf8))
        let input = try #require(JSONSerialization.jsonObject(with: content) as? [String: Any])
        let items = try #require(input["items"] as? [[String: String]])
        #expect(items.count == 1)
        let item = try #require(items.first)
        let id = try #require(item["id"])
        let source = try #require(item["text"])
        #expect(id != "stamp")
        await calls.begin()
        try await Task.sleep(for: .milliseconds(id == "region-1" ? 60 : 10))
        await calls.end()
        let result = try JSONSerialization.data(withJSONObject: [
          "items": [["id": id, "text": source + "译文"]]
        ])
        let data = try JSONSerialization.data(withJSONObject: [
          "choices": [["message": ["content": String(decoding: result, as: UTF8.self)]]]
        ])
        let url = try #require(request.url)
        return (
          data,
          try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        )
      })
    let result = try await ProcessingProgress.$reporter.withValue(
      { await calls.record($0) },
      operation: {
        try await service.translateRegions(regions, source: "en", target: "zh", glossary: "")
      })
    for region in regions {
      #expect(
        result[region.id] == region.sourceText + (region.preserveOriginal == true ? "" : "译文"))
    }
    #expect(await calls.peak == 4)
    let progress = await calls.progress
    #expect(progress.filter { $0.id == "main" }.count == 1)
    #expect(progress.contains { $0.id == "translation-total" && $0.fraction == 1 })
  }

  @Test
  func translationRegionMappingIsolatesEachInput() async throws {
    let regions = [
      PDFTranslationRegion(
        id: "p0001-t0001", pageIndex: 0, kind: .nativeText,
        bounds: CGRect(x: 10, y: 40, width: 100, height: 14), sourceText: "First",
        preferredFontSize: 10),
      PDFTranslationRegion(
        id: "p0001-i0001", pageIndex: 0, kind: .imageOCR,
        bounds: CGRect(x: 150, y: 40, width: 100, height: 14), sourceText: "Second",
        preferredFontSize: 10),
    ]
    let responses = TranslationResponseSequence([
      .http(
        status: 200, headers: [:],
        body: Data(
          #"{"choices":[{"message":{"content":"{\"items\":[{\"id\":\"p0001-t0001\",\"text\":\"第一\"}]}"}}]}"#
            .utf8)),
      .http(
        status: 200, headers: [:],
        body: Data(
          #"{"choices":[{"message":{"content":"```json\n{\"items\":[{\"id\":\"p0001-i0001\",\"text\":\"第二\"}]}\n```"}}]}"#
            .utf8)),
    ])
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { request in
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: String]])
        let content = try #require(messages.last?["content"]?.data(using: .utf8))
        let input = try #require(JSONSerialization.jsonObject(with: content) as? [String: Any])
        let items = try #require(input["items"] as? [[String: String]])
        #expect(items.count == 1)
        return try await responses.send(request)
      }, sleeper: { _ in })

    let translated = try await service.translateRegions(
      regions, source: "en", target: "zh", glossary: "")

    #expect(translated == ["p0001-t0001": "第一", "p0001-i0001": "第二"])
    #expect(await responses.snapshot().requestCount == 2)
  }

  @Test
  func documentContextIsAnalyzedAndCarriedIntoRegionBatchesAndRetries() async throws {
    let regions = [
      PDFTranslationRegion(
        id: "first", pageIndex: 0, kind: .nativeText,
        bounds: CGRect(x: 0, y: 0, width: 100, height: 20), sourceText: "tear vesicles",
        preferredFontSize: 10),
      PDFTranslationRegion(
        id: "last", pageIndex: 9, kind: .imageOCR,
        bounds: CGRect(x: 0, y: 0, width: 100, height: 20), sourceText: "HSK", preferredFontSize: 10
      ),
    ]
    let analysisService = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { request in
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: String]])
        #expect(messages.last?["content"]?.contains("[Page 1]") == true)
        #expect(messages.last?["content"]?.contains("[Page 10]") == true)
        let endpoint = try #require(request.url)
        return (
          try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "tear=泪液; HSK=单纯疱疹性角膜炎"]]]
          ]),
          try #require(
            HTTPURLResponse(
              url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
        )
      })
    let context = try await analysisService.analyzeDocument(regions, source: "en", target: "zh")
    #expect(context.contains("tear=泪液"))
    let responses = TranslationResponseSequence([
      .http(
        status: 200, headers: [:],
        body: try JSONSerialization.data(withJSONObject: [
          "choices": [
            ["message": ["content": "{\"items\":[{\"id\":\"first\",\"text\":\"泪液囊泡\"}]}"]]
          ]
        ])),
      .http(
        status: 200, headers: [:],
        body: try JSONSerialization.data(withJSONObject: [
          "choices": [["message": ["content": "{\"items\":[{\"id\":\"last\",\"text\":\"HSK\"}]}"]]]
        ])),
    ])
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { request in
        let body = try #require(request.httpBody)
        let payload = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(payload["messages"] as? [[String: String]])
        #expect(messages.first?["content"]?.contains(context) == true)
        return try await responses.send(request)
      })
    let translated = try await service.translateRegions(
      regions, source: "en", target: "zh", glossary: "", documentContext: context)
    #expect(translated == ["first": "泪液囊泡", "last": "HSK"])
    #expect(await responses.snapshot().requestCount == 2)
  }

  @Test
  func translationRegionMappingRejectsAnUnexpectedIdentifier() async throws {
    let region = PDFTranslationRegion(
      id: "p0001-t0001", pageIndex: 0, kind: .nativeText,
      bounds: CGRect(x: 10, y: 40, width: 100, height: 14), sourceText: "First",
      preferredFontSize: 10)
    let responses = TranslationResponseSequence([
      .http(
        status: 200, headers: [:],
        body: Data(
          #"{"choices":[{"message":{"content":"{\"items\":[{\"id\":\"p0001-t9999\",\"text\":\"错误\"}]}"}}]}"#
            .utf8))
    ])
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { try await responses.send($0) }, sleeper: { _ in })

    do {
      _ = try await service.translateRegions(
        [region], source: "en", target: "zh", glossary: "")
      Issue.record("Unexpected translation region identifiers must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "translation_provider_failed")
      #expect(error.errorDescription?.contains("未请求的文字区域") == true)
    }
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
      #expect(error.recoverySuggestion?.contains("拆分 PDF") == true)
    }

    do {
      _ = try PDFTranslationPolicy.totalCharacters(
        afterAdding: 1, to: PDFTranslationPolicy.maximumCharacters)
      Issue.record("Oversized PDF translation text should be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.code == "processing_limit_exceeded")
      #expect(error.errorDescription?.contains("待翻译字符") == true)
      #expect(error.recoverySuggestion?.contains("删除不需要翻译的页面") == true)
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
    model.capabilities = NativeCapabilities.response
    model.selection.source = "pdf"
    model.selection.target = "pdf"
    await model.importDocuments([first, first])
    await model.importDocuments([first, second, second], appending: true)

    #expect(model.documents.map(\.name) == ["first.pdf", "second.pdf"])
    #expect(model.documents.map(\.size) == [5, 6])
  }

  @Test @MainActor
  func documentSelectionRequiresACompleteRoute() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-route-import-test-\(UUID().uuidString).pdf")
    try Data("sample".utf8).write(to: temporary)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let model = AppModel()
    model.capabilities = NativeCapabilities.response

    #expect(!model.canSelectDocuments)
    await model.importDocuments([temporary])
    #expect(model.documents.isEmpty)
    #expect(model.errorMessage == "请先选择源格式和目标格式。")

    model.selection.source = "pdf"
    #expect(!model.canSelectDocuments)

    model.selection.target = "pdf"
    #expect(model.canSelectDocuments)
    await model.importDocuments([temporary])
    #expect(model.documents.map(\.name) == [temporary.lastPathComponent])

    model.isSubmitting = true
    #expect(!model.canSelectDocuments)
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
  func preflightRejectsEmptyFilesBeforeProcessing() async throws {
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let document = SelectedDocument(url: URL(fileURLWithPath: "/tmp/empty.pdf"), size: 0)
    let result = await NativeDocumentEngine().preflight(
      route: route, files: [document], options: JobOptions())

    #expect(!result.ok)
    #expect(result.blockingIssues.contains { $0.code == "empty_file" })
  }

  @Test @MainActor
  func preflightRejectsMultipleFilesForSingleDocumentRoutes() async throws {
    let editRoute = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let translateRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let files = [
      SelectedDocument(url: URL(fileURLWithPath: "/tmp/first.pdf"), size: 4),
      SelectedDocument(url: URL(fileURLWithPath: "/tmp/second.pdf"), size: 4),
    ]

    let engine = NativeDocumentEngine()
    let edit = await engine.preflight(route: editRoute, files: files, options: JobOptions())
    let translate = await engine.preflight(
      route: translateRoute, files: files, options: JobOptions())

    #expect(edit.blockingIssues.contains { $0.code == "single_file_required" })
    #expect(translate.blockingIssues.contains { $0.code == "single_file_required" })

    var mergeOptions = JobOptions()
    mergeOptions.editAction = "merge"
    let merge = await engine.preflight(route: editRoute, files: files, options: mergeOptions)
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

    let preflight = await engine.preflight(route: route, files: files, options: options)
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
    let invalidAction = await engine.preflight(route: route, files: files, options: options)
    #expect(invalidAction.blockingIssues.contains { $0.code == "invalid_edit_action" })
  }

  @Test @MainActor
  func cropBoxParsingRequiresExactlyFourNumericFields() async throws {
    let route = try #require(NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let file = SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 4)

    for value in ["0,,0,100,100", "0,abc,0,100,100", "0,0,100,100,200"] {
      do {
        _ = try JobOptionValidator.parseCropBox(value)
        Issue.record("Malformed crop components must not be discarded")
      } catch let error as NativeDocumentError {
        #expect(error.code == "invalid_option")
      }

      var options = JobOptions()
      options.cropPages = "1"
      options.cropBox = value
      let preflight = await NativeDocumentEngine().preflight(
        route: route, files: [file], options: options)
      #expect(preflight.blockingIssues.contains { $0.code == "invalid_crop_box" })
    }

    let valid = try JobOptionValidator.parseCropBox(" 0 , 10 , 100 , 200 ")
    #expect(valid == CGRect(x: 0, y: 10, width: 100, height: 190))
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

    let translationPreflight = await engine.preflight(
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
    let ocrPreflight = await engine.preflight(
      route: ocrRoute, files: [pdf], options: ocr)
    #expect(ocrPreflight.blockingIssues.contains { $0.code == "invalid_ocr_output" })
    #expect(ocrPreflight.blockingIssues.contains { $0.code == "invalid_ocr_language" })
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

    let preflight = await engine.preflight(
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
  func credentialSettingsRejectInvalidValuesBeforeKeychainWrite() async {
    let store = TestCredentialStore(
      values: [.deepseek: "existing-deepseek", .openAI: "existing-openai"])
    let settings = ProviderSettingsModel(store: store)
    let appModel = AppModel(backend: NativeDocumentEngine(credentialStore: store))
    await settings.reload(showSuccess: false)
    settings.deepseekKey = "first\r\nsecond"
    settings.openAIKey = "replacement-openai"

    await settings.save(appModel: appModel)

    #expect(settings.isLoaded)
    #expect(!settings.isSaving)
    #expect(settings.messageIsError)
    #expect(settings.message.contains("DeepSeek"))
    #expect(settings.message.contains("单行"))
    #expect(settings.announcement?.priority == .high)
    #expect(store.writes.isEmpty)
    #expect(store.values[.deepseek] == "existing-deepseek")
    #expect(store.values[.openAI] == "existing-openai")
  }

  @Test @MainActor
  func credentialSettingsSeparateStoredStateFromUnsavedDrafts() async {
    let store = TestCredentialStore(
      values: [.deepseek: "stored-deepseek", .openAI: ""])
    let settings = ProviderSettingsModel(store: store)
    await settings.reload(showSuccess: false)

    var state = settings.rowState(for: .deepseek)
    #expect(state.storage == .configured)
    #expect(state.statusLabel == "已配置")
    #expect(state.statusStyle == .configured)
    #expect(state.canRemoveStoredValue)
    #expect(!state.hasUnsavedChanges)

    settings.deepseekKey = ""
    state = settings.rowState(for: .deepseek)
    #expect(state.storage == .configured)
    #expect(state.statusLabel == "已配置 · 待保存")
    #expect(state.statusStyle == .pending)
    #expect(state.canRemoveStoredValue)
    #expect(state.hasUnsavedChanges)

    settings.openAIKey = "new-openai"
    state = settings.rowState(for: .openAI)
    #expect(state.storage == .notConfigured)
    #expect(state.statusLabel == "未配置 · 待保存")
    #expect(state.statusStyle == .pending)
    #expect(!state.canRemoveStoredValue)

    settings.openAIKey = "first\nsecond"
    state = settings.rowState(for: .openAI)
    #expect(state.storage == .notConfigured)
    #expect(state.statusLabel == "未配置 · 输入无效，未保存")
    #expect(state.statusStyle == .invalid)
    #expect(state.draftValidationError == .invalidCharacters)
    #expect(!state.canRemoveStoredValue)
  }

  @Test
  func providerCredentialPolicyEnforcesCharactersAndByteBoundary() throws {
    #expect(
      try ProviderCredentialPolicy.normalizedValue(
        "  sk-deepseek-valid  ", allowingEmpty: false) == "sk-deepseek-valid")
    #expect(
      try ProviderCredentialPolicy.normalizedValue(
        "sk-proj-openai-valid", allowingEmpty: false) == "sk-proj-openai-valid")
    #expect(
      try ProviderCredentialPolicy.normalizedValue("   ", allowingEmpty: true).isEmpty)

    let boundary = String(repeating: "x", count: ProviderCredentialPolicy.maximumUTF8Bytes)
    #expect(
      try ProviderCredentialPolicy.normalizedValue(boundary, allowingEmpty: false).utf8.count
        == ProviderCredentialPolicy.maximumUTF8Bytes)

    for invalid in [
      "first\rsecond", "first\nsecond", "first\u{0000}second", "first\u{007F}second",
    ] {
      do {
        _ = try ProviderCredentialPolicy.normalizedValue(invalid, allowingEmpty: false)
        Issue.record("Control characters must be rejected")
      } catch let error as ProviderCredentialValidationError {
        #expect(error == .invalidCharacters)
      }
    }

    do {
      _ = try ProviderCredentialPolicy.normalizedValue(
        String(repeating: "x", count: ProviderCredentialPolicy.maximumUTF8Bytes + 1),
        allowingEmpty: false)
      Issue.record("Oversized credentials must be rejected")
    } catch let error as ProviderCredentialValidationError {
      #expect(error == .tooLong)
    }

    do {
      _ = try ProviderCredentialPolicy.normalizedValue("   ", allowingEmpty: false)
      Issue.record("A required credential must not be empty")
    } catch let error as ProviderCredentialValidationError {
      #expect(error == .missing)
    }
  }

  @Test(arguments: [true, false]) @MainActor
  func credentialBackgroundChecksNeverPromptAndSuccessfulAuthorizationIsReused(
    protectedStorage: Bool
  ) async throws {
    let keychain = SimulatedKeychain(dataProtectionAvailable: protectedStorage)
    if protectedStorage {
      keychain.protected[ProviderCredential.deepseek.rawValue] = Data("saved-key".utf8)
    } else {
      keychain.legacy[ProviderCredential.deepseek.rawValue] = Data("saved-key".utf8)
    }
    keychain.requiresAuthentication = true
    let worker = ProviderCredentialWorker(store: ProviderCredentialStore(client: keychain.client))
    let settings = ProviderSettingsModel(worker: worker)
    let status = await worker.status()
    #expect(status.requiresAuthorization == [.deepseek])
    #expect(status.configured[.deepseek] == false)
    await settings.reload(showSuccess: false)
    #expect(!settings.isLoaded)
    #expect(settings.rowState(for: .deepseek).storage == .awaitingAuthorization)
    #expect(!settings.messageIsError)
    #expect(keychain.interactiveReads == 0)
    #expect(keychain.metadataReads + keychain.silentReads > 0)

    #expect(try await worker.value(for: .deepseek) == "saved-key")
    let readsAfterAuthorization = keychain.interactiveReads
    #expect(readsAfterAuthorization == 1)
    #expect(try await worker.value(for: .deepseek) == "saved-key")
    await settings.reload(showSuccess: false)
    #expect(settings.isLoaded)
    let authorized = await worker.status()
    #expect(authorized.configured[.deepseek] == true)
    #expect(authorized.requiresAuthorization.isEmpty)
    #expect(keychain.interactiveReads == readsAfterAuthorization)
    let stored = protectedStorage ? keychain.protected : keychain.legacy
    #expect(stored[ProviderCredential.deepseek.rawValue] == Data("saved-key".utf8))
  }

  @Test @MainActor
  func keychainRejectsInvalidCredentialsBeforeMutation() {
    let keychain = SimulatedKeychain()
    let store = ProviderCredentialStore(client: keychain.client)
    let invalidValues = [
      "first\nsecond",
      String(repeating: "x", count: ProviderCredentialPolicy.maximumUTF8Bytes + 1),
    ]

    for value in invalidValues {
      do {
        try store.setValue(value, for: .deepseek)
        Issue.record("Invalid credentials must not reach Keychain")
      } catch is ProviderCredentialValidationError {
        // Expected.
      } catch {
        Issue.record("Unexpected error: \(error.localizedDescription)")
      }
    }

    #expect(keychain.protected.isEmpty)
    #expect(keychain.legacy.isEmpty)
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
  func preflightReportsKeychainReadFailureSeparatelyFromMissingKey() async throws {
    let store = TestCredentialStore(readFailures: [.deepseek])
    let engine = NativeDocumentEngine(credentialStore: store)
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let file = SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 1)

    let result = await engine.preflight(
      route: route, files: [file], options: JobOptions())

    #expect(result.blockingIssues.contains { $0.code == "provider_keychain_unavailable" })
    #expect(!result.blockingIssues.contains { $0.code == "provider_not_configured" })
  }

  @Test @MainActor
  func invalidTranslationProviderDoesNotReadAnyCredential() async throws {
    let store = TestCredentialStore(readFailures: Set(ProviderCredential.allCases))
    let engine = NativeDocumentEngine(credentialStore: store)
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let file = SelectedDocument(url: URL(fileURLWithPath: "/tmp/source.pdf"), size: 1)
    var options = JobOptions()
    options.provider = "unknown"

    let result = await engine.preflight(route: route, files: [file], options: options)

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
  func cancelledResultSavingPreservesExistingFileAndRemovesTemporaryCopy() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-save-cancellation-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let source = temporary.appendingPathComponent("source.pdf")
    let destination = temporary.appendingPathComponent("destination.pdf")
    #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
    let sourceHandle = try FileHandle(forWritingTo: source)
    try sourceHandle.truncate(atOffset: 1_024 * 1_024)
    try sourceHandle.close()
    try Data("existing result".utf8).write(to: destination)

    let saveTask = Task.detached {
      try AtomicResultSaver.copyReplacing(
        source: source, destination: destination, chunkSize: 1)
    }
    var transferStarted = false
    for _ in 0..<200 {
      let entries = try FileManager.default.contentsOfDirectory(atPath: temporary.path)
      if entries.contains(where: { $0.hasPrefix(".transall-save-") }) {
        transferStarted = true
        break
      }
      try await Task.sleep(for: .milliseconds(1))
    }

    saveTask.cancel()
    var receivedCancellation = false
    do {
      try await saveTask.value
      Issue.record("Cancelled result saving should not replace the destination")
    } catch is CancellationError {
      receivedCancellation = true
    } catch {
      Issue.record("Cancelled result saving returned an unexpected error: \(error)")
    }

    #expect(transferStarted)
    #expect(receivedCancellation)
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
  func restoredResultSavingRejectsExistingDestinationButAllowsNewPath() throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-restored-save-policy-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let existing = temporary.appendingPathComponent("existing.pdf")
    let newDestination = temporary.appendingPathComponent("new.pdf")
    try Data("existing".utf8).write(to: existing)

    do {
      try ResultSavePolicy.validate(destination: existing, originalDocuments: nil)
      Issue.record("A restored result should not replace an existing destination")
    } catch let error as ResultSaveError {
      #expect(error.localizedDescription.contains("恢复的任务"))
      #expect(error.localizedDescription.contains("不能替换已有文件"))
    }

    try ResultSavePolicy.validate(destination: newDestination, originalDocuments: nil)
  }

  @Test @MainActor
  func jobSubmissionStartsOnceAndCancelsWithoutReportingFailure() async {
    let gate = DeletionRaceGate()
    let fallbackJob = completedTestJob()
    var creationCalls = 0
    var submittedDocuments: [SelectedDocument] = []
    var submittedOptions = JobOptions()
    let model = AppModel(
      backend: NativeDocumentEngine(),
      jobCreator: { _, documents, options in
        creationCalls += 1
        submittedDocuments = documents
        submittedOptions = options
        await gate.markStarted()
        do {
          try await Task.sleep(for: .seconds(60))
          return fallbackJob
        } catch is CancellationError {
          await gate.markCancelled()
          throw CancellationError()
        }
      })
    let original = SelectedDocument(
      url: URL(fileURLWithPath: "/tmp/transall-submission-source.txt"), size: 128)
    model.capabilities = NativeCapabilities.response
    model.selection.source = "data"
    model.selection.target = "pdf"
    model.documents = [original]
    model.options.watermark = "submitted option snapshot"

    model.startJob()

    #expect(model.isSubmitting)
    #expect(!model.canRun)
    model.startJob()
    await gate.waitUntilStarted()
    #expect(creationCalls == 1)

    model.documents = [
      SelectedDocument(url: URL(fileURLWithPath: "/tmp/replacement.txt"), size: 64)
    ]
    model.options.watermark = "later option"
    await model.cancelJobSubmission()

    await gate.waitUntilCancelled()
    #expect(submittedDocuments == [original])
    #expect(submittedOptions.watermark == "submitted option snapshot")
    #expect(!model.isSubmitting)
    #expect(model.currentJob == nil)
    #expect(model.errorMessage == nil)
  }

  @Test @MainActor
  func successfulJobSubmissionPersistsAndPollsCreatedJob() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-submission-success-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let input = temporary.appendingPathComponent("source.txt")
    try Data("source document".utf8).write(to: input)
    let suiteName = "transall-submission-success-preferences-\(UUID().uuidString)"
    let preferences = try #require(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data", isDirectory: true))
    let model = AppModel(backend: engine, preferences: preferences)
    defer { model.prepareForTermination() }
    await engine.start()
    model.capabilities = NativeCapabilities.response
    model.selection.source = "data"
    model.selection.target = "pdf"
    model.documents = [SelectedDocument(url: input, size: 15)]

    await model.runJob()

    let submittedJob = try #require(model.currentJob)
    #expect(preferences.string(forKey: "transall.native.lastJobId") == submittedJob.id)
    for _ in 0..<200 where model.currentJob?.isFinished != true {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.currentJob?.status == "done")
    #expect(!model.isSubmitting)
  }

  @Test @MainActor
  func successfulResultSavingRevealsDestinationAfterDownload() async {
    let destination = URL(fileURLWithPath: "/tmp/transall-successful-result.pdf")
    let recorder = ResultSaveRecorder()
    let job = completedTestJob()
    let model = AppModel(
      backend: NativeDocumentEngine(),
      resultDestinationPicker: { suggestedName in
        #expect(suggestedName == job.output)
        return destination
      },
      resultDownloader: { jobID, downloadedDestination, _ in
        recorder.recordDownload(jobID: jobID, destination: downloadedDestination)
      },
      resultRevealer: { recorder.recordReveal(destination: $0) })
    model.currentJob = job

    model.startSavingResult()
    await recorder.waitUntilRevealed()

    #expect(recorder.downloadedJobID == job.id)
    #expect(recorder.downloadedDestination == destination)
    #expect(recorder.revealedDestination == destination)
    #expect(!model.isSaving)
    #expect(model.errorMessage == nil)
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

  @Test
  func inputCopyEnforcesCumulativeLimitAndRemovesCompletedCopies() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-cumulative-copy-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let inputDirectory = temporary.appendingPathComponent("Input", isDirectory: true)
    try FileManager.default.createDirectory(at: inputDirectory, withIntermediateDirectories: true)

    let first = temporary.appendingPathComponent("first.bin")
    let second = temporary.appendingPathComponent("second.bin")
    #expect(FileManager.default.createFile(atPath: first.path, contents: nil))
    #expect(FileManager.default.createFile(atPath: second.path, contents: nil))
    let firstHandle = try FileHandle(forWritingTo: first)
    try firstHandle.truncate(atOffset: 700 * 1_024)
    try firstHandle.close()
    let secondHandle = try FileHandle(forWritingTo: second)
    try secondHandle.truncate(atOffset: 400 * 1_024)
    try secondHandle.close()

    do {
      _ = try await JobStorage.copyInputs(
        [SelectedDocument(url: first, size: 1), SelectedDocument(url: second, size: 1)],
        to: inputDirectory, maximumBytes: 1_024 * 1_024, maximumMB: 1,
        chunkSize: 64 * 1_024)
      Issue.record("Combined input size should enforce the copy limit")
    } catch {
      #expect(error.localizedDescription.contains("1 MB"))
    }

    #expect(try FileManager.default.contentsOfDirectory(atPath: inputDirectory.path).isEmpty)
  }

  @Test @MainActor
  func cancellingJobCreationRemovesIncompleteTaskDirectory() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-cancelled-creation-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let source = temporary.appendingPathComponent("source.txt")
    try Data("source".utf8).write(to: source)
    let gate = DeletionRaceGate()
    let dataDirectory = temporary.appendingPathComponent("Data", isDirectory: true)
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: dataDirectory,
      inputCopier: { _, inputDirectory, _, _ in
        try Data("partial".utf8).write(
          to: inputDirectory.appendingPathComponent("1-source.txt"))
        await gate.markStarted()
        do {
          try await Task.sleep(for: .seconds(60))
          return []
        } catch is CancellationError {
          await gate.markCancelled()
          throw CancellationError()
        }
      })
    await engine.start()
    let route = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" && $0.source == "data" })
    let creation = Task {
      try await engine.createJob(
        route: route, files: [SelectedDocument(url: source, size: 6)],
        options: JobOptions())
    }

    await gate.waitUntilStarted()
    creation.cancel()
    do {
      _ = try await creation.value
      Issue.record("Cancelled task creation should not return a job")
    } catch is CancellationError {
    } catch {
      Issue.record("Cancelled task creation returned an unexpected error: \(error)")
    }

    await gate.waitUntilCancelled()
    let jobsDirectory = dataDirectory.appendingPathComponent("Jobs", isDirectory: true)
    #expect(try FileManager.default.contentsOfDirectory(atPath: jobsDirectory.path).isEmpty)
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
  func translationJobReadsSelectedCredentialExactlyOnce() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "transall-translation-key-read-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    let translationRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_translate" })
    let sourceText = temporary.appendingPathComponent("source.txt")
    let sourcePDF = temporary.appendingPathComponent("source.pdf")
    try Data("translation credential fixture".utf8).write(to: sourceText, options: .atomic)
    _ = try await NativeDocumentProcessor.process(
      route: textRoute, inputs: [sourceText], options: JobOptions(), outputURL: sourcePDF,
      apiKey: nil)
    let sourceSize = try #require(
      sourcePDF.resourceValues(forKeys: [.fileSizeKey]).fileSize)

    let store = TestCredentialStore(values: [.deepseek: "test-key"])
    let capturedKeys = APIKeyCapture()
    let engine = NativeDocumentEngine(
      dataDirectoryOverride: temporary.appendingPathComponent("Data"), credentialStore: store,
      jobProcessor: { _, _, _, outputURL, apiKey in
        await capturedKeys.append(apiKey)
        try FileManager.default.copyItem(at: sourcePDF, to: outputURL)
        return NativeDocumentProcessor.Result(outputURL: outputURL, logs: [])
      })
    defer { engine.prepareForTermination() }
    await engine.start()

    var job = try await engine.createJob(
      route: translationRoute,
      files: [SelectedDocument(url: sourcePDF, size: Int64(sourceSize))],
      options: JobOptions())
    for _ in 0..<200 where !job.isFinished {
      try await Task.sleep(for: .milliseconds(10))
      job = try engine.job(id: job.id)
    }

    #expect(job.status == "done")
    #expect(store.reads == [.deepseek])
    #expect(await capturedKeys.snapshot() == ["test-key"])
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
  func runningJobLocksRouteControlsAndRejectsMutations() async {
    let model = AppModel(backend: NativeDocumentEngine())
    model.capabilities = NativeCapabilities.response
    model.selection.source = "pdf"
    model.selection.target = "md"
    let original = SelectedDocument(
      url: URL(fileURLWithPath: "/tmp/running-original.pdf"), size: 128)
    model.documents = [original]
    model.currentJob = testJob(status: "running")

    let selectedRoute = model.selection
    #expect(model.formatReversalDisabledReason == model.routeChangeLock?.helpText)
    #expect(!model.reverseFormats(expectedSelection: selectedRoute))
    #expect(model.selection == selectedRoute)
    #expect(model.routeChangeLock == .running)
    #expect(model.routeChangeLock?.statusLabel == "任务运行中")
    #expect(!model.canChangeRoute)
    #expect(!model.canEditTaskDraft)
    #expect(!model.canSelectDocuments)
    #expect(model.taskDraftLockMessage == "任务运行中，完成或取消后可修改文件和参数")

    model.chooseFormat("image", animated: false)
    #expect(model.selection.source == "pdf")
    #expect(model.selection.target == "md")
    #expect(model.errorMessage == "任务运行中，请先取消任务再更换路径。")

    model.resetRoute(animated: false)
    #expect(model.selection.source == "pdf")
    #expect(model.selection.target == "md")
    #expect(model.currentJob?.status == "running")
    #expect(model.errorMessage == "任务运行中，请先取消任务再重选路径。")

    model.removeDocument(original)
    #expect(model.documents.map(\.id) == [original.id])

    await model.importDocuments(
      [URL(fileURLWithPath: "/tmp/running-replacement.pdf")], appending: false)
    #expect(model.documents.map(\.id) == [original.id])
    #expect(model.errorMessage == "任务运行中，完成或取消后可修改文件和参数。")

    model.currentJob = testJob(status: "done")
    #expect(model.canEditTaskDraft)
    #expect(model.canSelectDocuments)
    #expect(model.taskDraftLockMessage == nil)
    model.removeDocument(original)
    #expect(model.documents.isEmpty)
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

    await model.deleteCurrentJob(id: job.id)

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
      await model.deleteCurrentJob(id: job.id)

      #expect(model.currentJob == nil)
      #expect(!model.isDeletingJob)
      #expect(!FileManager.default.fileExists(atPath: jobDirectory.path))
    }
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
    try persistTestCompletionReceipt(output: output, in: jobDirectory)

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
  func layoutTranslationKeepsPageGeometryAndAddsImageTextRegions() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-layout-translation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let sourceText = temporary.appendingPathComponent("source.txt")
    try Data("Native title\n\nNative paragraph".utf8).write(to: sourceText, options: .atomic)
    let sourcePDF = temporary.appendingPathComponent("source.pdf")
    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    _ = try await NativeDocumentProcessor.process(
      route: textRoute, inputs: [sourceText], options: JobOptions(), outputURL: sourcePDF,
      apiKey: nil)
    let document = try #require(PDFDocument(url: sourcePDF))
    let raster = try #require(CGPDFDocument(sourcePDF as CFURL))

    let regions = try PDFLayoutTranslation.extractRegions(
      document: document, rasterDocument: raster, languages: ["en-US"],
      recognizer: { _, _ in
        [
          PDFLayoutTranslation.OCRObservation(
            text: "Image label",
            normalizedBounds: CGRect(x: 0.68, y: 0.12, width: 0.2, height: 0.05),
            confidence: 0.99)
        ]
      })

    #expect(regions.contains { $0.kind == .nativeText })
    #expect(regions.filter { $0.kind == .imageOCR }.map(\.id) == ["p0001-i0001"])
    #expect(regions.map(\.id).count == Set(regions.map(\.id)).count)
    let output = temporary.appendingPathComponent("translated-layout.pdf")
    let translations = Dictionary(uniqueKeysWithValues: regions.map { ($0.id, "译") })
    let report = try PDFLayoutTranslation.writeTranslatedPDF(
      inputURL: sourcePDF, regions: regions, translations: translations, outputURL: output)
    let translated = try #require(PDFDocument(url: output))

    #expect(report.pageCount == document.pageCount)
    #expect(report.imageOCRRegionCount == 1)
    #expect(report.overflowRegionIDs.isEmpty)
    #expect(translated.pageCount == document.pageCount)
    #expect(
      translated.page(at: 0)?.bounds(for: .mediaBox) == document.page(at: 0)?.bounds(for: .mediaBox)
    )
    #expect(translated.string?.contains("译") == true)
  }

  @Test
  func layoutTranslationUsesVisionForImageTextOnAMixedPage() throws {
    let retainedDirectory = ProcessInfo.processInfo.environment["TRANSALL_LAYOUT_SMOKE_OUTPUT"]
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
    let temporary =
      retainedDirectory
      ?? FileManager.default.temporaryDirectory.appendingPathComponent(
        "transall-layout-vision-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    let shouldRemoveTemporary = retainedDirectory == nil
    defer {
      if shouldRemoveTemporary { try? FileManager.default.removeItem(at: temporary) }
    }
    let source = temporary.appendingPathComponent("mixed-source.pdf")
    let output = temporary.appendingPathComponent("mixed-translated.pdf")
    try writeMixedLayoutFixture(to: source)
    let document = try #require(PDFDocument(url: source))
    let raster = try #require(CGPDFDocument(source as CFURL))

    let regions = try PDFLayoutTranslation.extractRegions(
      document: document, rasterDocument: raster, languages: ["en-US"])
    let nativeText = regions.filter { $0.kind == .nativeText }.map(\.sourceText).joined(
      separator: " ")
    let imageText = regions.filter { $0.kind == .imageOCR }.map(\.sourceText).joined(separator: " ")
    if retainedDirectory != nil {
      for region in regions {
        print(
          "LAYOUT_REGION=\(region.kind.rawValue) \(region.id) \(region.bounds) \(region.sourceText)"
        )
      }
    }

    #expect(nativeText.localizedCaseInsensitiveContains("native heading"))
    #expect(imageText.localizedCaseInsensitiveContains("image label"))
    #expect(!imageText.localizedCaseInsensitiveContains("native heading"))
    let imageRegions = regions.filter { $0.kind == .imageOCR }
    let firstImageRegion = try #require(imageRegions.first)
    let imageBounds = imageRegions.dropFirst().reduce(firstImageRegion.bounds) {
      $0.union($1.bounds)
    }
    #expect(imageBounds.width > 150)
    #expect(imageBounds.height > 25)
    #expect(
      CGRect(x: 440, y: 160, width: 340, height: 170).contains(
        CGPoint(x: imageBounds.midX, y: imageBounds.midY)))
    let translations = Dictionary(
      uniqueKeysWithValues: regions.map {
        ($0.id, $0.kind == .nativeText ? "原生区域译文" : "图片区域译文")
      })
    let report = try PDFLayoutTranslation.writeTranslatedPDF(
      inputURL: source, regions: regions, translations: translations, outputURL: output)

    #expect(report.nativeRegionCount >= 1)
    #expect(report.imageOCRRegionCount >= 1)
    #expect(report.overflowRegionIDs.isEmpty)
    #expect(PDFDocument(url: output)?.pageCount == 1)
    if retainedDirectory != nil {
      print("LAYOUT_SMOKE_SOURCE=\(source.path)")
      print("LAYOUT_SMOKE_OUTPUT=\(output.path)")
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
  func translationRejectsInvalidCredentialBeforeSendingRequest() async throws {
    let invalidKeys = [
      "first\r\nsecond",
      String(repeating: "x", count: ProviderCredentialPolicy.maximumUTF8Bytes + 1),
    ]

    for key in invalidKeys {
      let responses = TranslationResponseSequence([])
      let service = TranslationService(
        provider: "deepseek", apiKey: key,
        requestSender: { try await responses.send($0) },
        sleeper: { await responses.record(delay: $0) })

      do {
        _ = try await service.translate("source", source: "en", target: "zh", glossary: "")
        Issue.record("Invalid credentials must fail before a request starts")
      } catch let error as NativeDocumentError {
        #expect(error.errorDescription?.contains("API Key 格式无效") == true)
      }
      let snapshot = await responses.snapshot()
      #expect(snapshot.requestCount == 0)
      #expect(snapshot.delays.isEmpty)
    }
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
  func translationDefaultTransportRejectsRedirectsBeforeFollowingThem() async throws {
    let configuration = TranslationService.sessionConfiguration()
    configuration.protocolClasses = [RedirectingResponseURLProtocol.self]
    RedirectingResponseURLProtocol.probe.reset()

    var request = URLRequest(
      url: try #require(URL(string: "https://translation.test/redirect")))
    request.httpMethod = "POST"
    request.setValue("Bearer test-secret", forHTTPHeaderField: "Authorization")
    request.httpBody = Data("private document text".utf8)

    do {
      _ = try await TranslationService.boundedData(
        for: request, configuration: configuration, maximumBytes: 700)
      Issue.record("Translation redirects must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("保护 API Key 和文档文字") == true)
    }

    try await Task.sleep(for: .milliseconds(40))
    let snapshot = RedirectingResponseURLProtocol.probe.snapshot()
    #expect(snapshot.originalRequestCount == 1)
    #expect(snapshot.redirectedRequestCount == 0)
    #expect(snapshot.wasStopped)
  }

  @Test
  func translationRejectsWhitespaceOnlyContent() async throws {
    let body = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": " \n\t "]]]
    ])
    let responses = TranslationResponseSequence([
      .http(status: 200, headers: [:], body: body)
    ])
    let service = TranslationService(
      provider: "openai", apiKey: "test-key",
      requestSender: { try await responses.send($0) },
      sleeper: { await responses.record(delay: $0) })

    do {
      _ = try await service.translate("source", source: "en", target: "zh", glossary: "")
      Issue.record("Whitespace-only translations must be rejected")
    } catch let error as NativeDocumentError {
      #expect(error.errorDescription?.contains("没有返回译文") == true)
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
  func nativePDFEditValidatesCropAgainstPageBounds() async throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("transall-crop-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let textRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "text_to_pdf" })
    let editRoute = try #require(
      NativeCapabilities.routes.first { $0.kind == "pdf_edit" })
    let text = temporary.appendingPathComponent("source.txt")
    let source = temporary.appendingPathComponent("source.pdf")
    try Data("crop test".utf8).write(to: text, options: .atomic)
    _ = try await NativeDocumentProcessor.process(
      route: textRoute, inputs: [text], options: JobOptions(), outputURL: source, apiKey: nil)

    var validOptions = JobOptions()
    validOptions.cropPages = "1"
    validOptions.cropBox = "10,20,500,700"
    let validOutput = temporary.appendingPathComponent("valid-crop.pdf")
    _ = try await NativeDocumentProcessor.process(
      route: editRoute, inputs: [source], options: validOptions, outputURL: validOutput,
      apiKey: nil)
    let validDocument = try #require(PDFDocument(url: validOutput))
    let applied = try #require(validDocument.page(at: 0)?.bounds(for: .cropBox))
    #expect(abs(applied.minX - 10) <= 0.001)
    #expect(abs(applied.minY - 20) <= 0.001)
    #expect(abs(applied.width - 490) <= 0.001)
    #expect(abs(applied.height - 680) <= 0.001)

    for (index, cropBox) in [
      "700,900,800,1000", "-1,0,100,100", "0,0,1e150,1e150",
    ].enumerated() {
      var invalidOptions = JobOptions()
      invalidOptions.cropPages = "1"
      invalidOptions.cropBox = cropBox
      let invalidOutput = temporary.appendingPathComponent("invalid-crop-\(index).pdf")
      do {
        _ = try await NativeDocumentProcessor.process(
          route: editRoute, inputs: [source], options: invalidOptions, outputURL: invalidOutput,
          apiKey: nil)
        Issue.record("Out-of-page crop boxes must be rejected")
      } catch let error as NativeDocumentError {
        #expect(error.code == "invalid_option")
        #expect(error.errorDescription?.contains("第 1 页当前页面范围") == true)
      }
      #expect(!FileManager.default.fileExists(atPath: invalidOutput.path))
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

  private func writeMixedLayoutFixture(to url: URL) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 842, height: 595)
    guard let consumer = CGDataConsumer(url: url as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
    else {
      throw TestPersistenceError.unavailable
    }
    context.beginPDFPage(nil)
    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(mediaBox)
    drawFixtureLine(
      "Native heading", at: CGPoint(x: 56, y: 500), fontSize: 30,
      color: CGColor(gray: 0.08, alpha: 1), context: context)
    drawFixtureLine(
      "This paragraph remains native PDF text.", at: CGPoint(x: 58, y: 450), fontSize: 15,
      color: CGColor(gray: 0.18, alpha: 1), context: context)

    guard
      let imageContext = CGContext(
        data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
      throw TestPersistenceError.unavailable
    }
    imageContext.setFillColor(
      CGColor(red: 0.84, green: 0.91, blue: 0.99, alpha: 1))
    imageContext.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
    drawFixtureLine(
      "IMAGE LABEL", at: CGPoint(x: 45, y: 145), fontSize: 58,
      color: CGColor(gray: 0.04, alpha: 1), context: imageContext)
    guard let image = imageContext.makeImage() else { throw TestPersistenceError.unavailable }
    context.draw(image, in: CGRect(x: 440, y: 160, width: 340, height: 170))
    context.endPDFPage()
    context.closePDF()
  }

  private func drawFixtureLine(
    _ text: String, at point: CGPoint, fontSize: CGFloat, color: CGColor, context: CGContext
  ) {
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          "Helvetica" as CFString, fontSize, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
      ])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = point
    CTLineDraw(line, context)
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

  private func completedTestJob() -> JobResponse {
    testJob(status: "done", output: "result.pdf")
  }

  private func testJob(
    status: String, output: String? = nil, error: String? = nil, errorHint: String? = nil
  ) -> JobResponse {
    let now = ISO8601DateFormatter().string(from: Date())
    return JobResponse(
      id: UUID().uuidString.lowercased(), kind: "text_to_pdf", status: status,
      inputs: ["source.txt"], createdAt: now, updatedAt: now, output: output,
      error: error, stage: status, message: "任务状态更新。", errorCode: nil,
      errorHint: errorHint, retryable: false, progress: status == "done" ? 100 : 0,
      cancelRequested: status == "cancelled", logs: [])
  }
}

@MainActor
private final class ResultSaveRecorder {
  private(set) var downloadedJobID: String?
  private(set) var downloadedDestination: URL?
  private(set) var revealedDestination: URL?
  private var revealWaiters: [CheckedContinuation<Void, Never>] = []

  func recordDownload(jobID: String, destination: URL) {
    downloadedJobID = jobID
    downloadedDestination = destination
  }

  func recordReveal(destination: URL) {
    revealedDestination = destination
    for waiter in revealWaiters { waiter.resume() }
    revealWaiters.removeAll()
  }

  func waitUntilRevealed() async {
    guard revealedDestination == nil else { return }
    await withCheckedContinuation { revealWaiters.append($0) }
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

private final class RedirectingResponseProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var originalRequestCount = 0
  private var redirectedRequestCount = 0
  private var wasStopped = false

  func reset() {
    lock.lock()
    originalRequestCount = 0
    redirectedRequestCount = 0
    wasStopped = false
    lock.unlock()
  }

  func recordRequest(host: String?) {
    lock.lock()
    if host == "translation.test" {
      originalRequestCount += 1
    } else if host == "redirected.test" {
      redirectedRequestCount += 1
    }
    lock.unlock()
  }

  func recordStop() {
    lock.lock()
    wasStopped = true
    lock.unlock()
  }

  func snapshot() -> (
    originalRequestCount: Int, redirectedRequestCount: Int, wasStopped: Bool
  ) {
    lock.lock()
    defer { lock.unlock() }
    return (originalRequestCount, redirectedRequestCount, wasStopped)
  }
}

private final class RedirectingResponseURLProtocol: URLProtocol, @unchecked Sendable {
  static let probe = RedirectingResponseProbe()

  override class func canInit(with request: URLRequest) -> Bool {
    ["translation.test", "redirected.test"].contains(request.url?.host)
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.probe.recordRequest(host: request.url?.host)
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    if url.host == "redirected.test" {
      guard
        let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1",
          headerFields: ["Content-Type": "application/json"])
      else {
        client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
        return
      }
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(#"{"unexpected":true}"#.utf8))
      client?.urlProtocolDidFinishLoading(self)
      return
    }

    guard let redirectedURL = URL(string: "https://redirected.test/leak"),
      let response = HTTPURLResponse(
        url: url, statusCode: 307, httpVersion: "HTTP/1.1",
        headerFields: ["Location": redirectedURL.absoluteString])
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    var redirectedRequest = request
    redirectedRequest.url = redirectedURL
    client?.urlProtocol(
      self, wasRedirectedTo: redirectedRequest, redirectResponse: response)
  }

  override func stopLoading() {
    Self.probe.recordStop()
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

private struct PersistedCompletionReceipt: Codable {
  let output: String
  let byteCount: Int64
  let sampleSHA256: String
}

private func persistTestJob(_ job: JobResponse, in directory: URL) throws {
  try JSONEncoder().encode(job).write(
    to: directory.appendingPathComponent("job.json"), options: .atomic)
}

private func persistTestCompletionReceipt(output: URL, in directory: URL) throws {
  let data = try Data(contentsOf: output, options: .mappedIfSafe)
  let sampleSize = 64 * 1_024
  var sample = data
  if data.count > sampleSize * 2 {
    sample = Data(data.prefix(sampleSize))
    sample.append(data.suffix(sampleSize))
  }
  let hash = SHA256.hash(data: sample)
    .map { String(format: "%02x", $0) }.joined()
  let receipt = PersistedCompletionReceipt(
    output: output.lastPathComponent, byteCount: Int64(data.count), sampleSHA256: hash)
  try JSONEncoder().encode(receipt).write(
    to: directory.appendingPathComponent("completion.json"), options: .atomic)
}

private func loadTestJSON<T: Decodable>(_ name: String, from directory: URL) throws -> T {
  try JSONDecoder().decode(T.self, from: Data(contentsOf: directory.appendingPathComponent(name)))
}

private final class TestCredentialStore: ProviderCredentialStoring, @unchecked Sendable {
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

  var errorDescription: String? { "测试本机配置不可用" }
}

private actor APIKeyCapture {
  private var keys: [String?] = []

  func append(_ key: String?) {
    keys.append(key)
  }

  func snapshot() -> [String?] {
    keys
  }
}

@MainActor
private final class SimulatedKeychain {
  var requiresAuthentication = false
  var interactiveReads = 0
  var silentReads = 0
  var metadataReads = 0
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
        if query[kSecReturnAttributes as String] as? Bool == true {
          metadataReads += 1
          return (errSecSuccess, nil)
        }
        let silent =
          (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed
          == true
        if silent { silentReads += 1 } else { interactiveReads += 1 }
        if requiresAuthentication && silent { return (errSecInteractionNotAllowed, nil) }
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

private actor RegionConcurrencyRecorder {
  var checkpoints: [[String: String]] = []
  func save(_ value: [String: String]) { checkpoints.append(value) }
  var progress: [TaskProgressLine] = []
  func record(_ line: TaskProgressLine) { progress.append(line) }
  var active = 0
  var peak = 0
  func begin() {
    active += 1
    peak = max(peak, active)
  }
  func end() { active -= 1 }
}
