import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import Foundation
import PDFKit
import Testing

@testable import TransallMac

@Suite(.serialized)
struct TranslationRecoveryTests {
  @Test
  func partialCheckpointResumesOnlyMatchingDocumentAndCannotBeExported() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old")
    let new = root.appendingPathComponent("new")
    for directory in [old, new] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let source = root.appendingPathComponent("source.pdf")
    try fixture(source)
    let regions = [region("first", page: 0), region("second", page: 0)]
    let partial = try TranslationRecoveryStore.create(
      inputURL: source, options: JobOptions(), pageCount: 1,
      regions: regions, translations: ["first": "第一段"], overflowRegionIDs: [],
      allowingIncomplete: true)
    try TranslationRecoveryStore.save(partial, in: old, allowingIncomplete: true)
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.load(in: old, inputURL: source, options: JobOptions())
    }
    #expect(throws: (any Error).self) { try TranslationRecoveryStore.validateForRendering(partial) }
    #expect(
      TranslationRecoveryStore.resumableTranslations(
        in: new, inputURL: source, options: JobOptions(), regions: regions) == ["first": "第一段"])
    var changed = JobOptions()
    changed.targetLanguage = "ja"
    #expect(
      TranslationRecoveryStore.resumableTranslations(
        in: new, inputURL: source, options: changed, regions: regions
      ).isEmpty)
    #expect(
      TranslationRecoveryStore.resumableTranslations(
        in: new, inputURL: source, options: JobOptions(),
        regions: [
          PDFTranslationRegion(
            id: "first", pageIndex: 0, kind: .nativeText, bounds: regions[0].bounds,
            sourceText: "DIFFERENT SOURCE", preferredFontSize: 12)
        ]
      ).isEmpty)
  }

  @Test
  func newContinuationInvalidatesOnlyItsOldFragmentsAndPersistsMetadata() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let old = root.appendingPathComponent("old")
    let new = root.appendingPathComponent("new")
    for directory in [old, new] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let source = root.appendingPathComponent("source.pdf")
    try fixture(source, pageCount: 2)
    let regions = [region("first", page: 0), region("second", page: 1), region("other", page: 1)]
    let text = ["first": "旧上半句", "second": "旧下半句", "other": "已完成的其他段落"]
    let saved = try TranslationRecoveryStore.create(
      inputURL: source, options: JobOptions(), pageCount: 2,
      regions: regions, translations: text, overflowRegionIDs: [])
    try TranslationRecoveryStore.save(saved, in: old)
    var linked = regions
    linked[0].continuationGroup = ["first", "second"]
    linked[1].continuationGroup = ["first", "second"]
    #expect(
      TranslationRecoveryStore.resumableTranslations(
        in: new, inputURL: source,
        options: JobOptions(), regions: linked) == ["other": text["other"]!])
    let newSaved = try TranslationRecoveryStore.create(
      inputURL: source, options: JobOptions(), pageCount: 2,
      regions: linked, translations: text, overflowRegionIDs: [])
    try TranslationRecoveryStore.save(newSaved, in: new)
    let loaded = try TranslationRecoveryStore.load(in: new, inputURL: source, options: JobOptions())
    #expect(loaded.regions == linked)
    #expect(
      TranslationRecoveryStore.resumableTranslations(
        in: new, inputURL: source,
        options: JobOptions(), regions: linked) == text)
  }

  @Test
  func layoutRecoveryHintSurvivesOptionalAndNSErrorBridging() throws {
    let error: NativeDocumentError? = .layoutOverflow(2)
    let hint = try #require(error?.recoverySuggestion)
    #expect(hint.contains("无需再次调用"))
    let underlying = try #require(error)
    #expect((underlying as NSError).localizedRecoverySuggestion == hint)
    let localized: any LocalizedError = underlying
    #expect(localized.recoverySuggestion == hint)
  }

  @Test
  func overflowAutomaticallyAppendsReadableNotesAndCanRenderOffline() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try fixture(source, pageCount: 3)
    let regions = [region("first", page: 0), region("second", page: 0), region("last", page: 2)]
    let translations = [
      "first": "FIRST "
        + String(repeating: "word word word word word word word word word word\n", count: 65)
        + "FIRST END",
      "second": "SECOND COMPLETE",
      "last": "LAST COMPLETE",
    ]
    let layoutOutput = directory.appendingPathComponent("layout.pdf")
    var options = JobOptions()
    options.outputMode = "preserve_layout"
    let report = try NativeDocumentProcessor.finishLayoutTranslation(
      input: source, options: options, pageCount: 3, regions: regions,
      translations: translations, outputURL: layoutOutput,
      expectedSourceSHA256: TranslationRecoveryStore.sourceFingerprint(inputURL: source))
    #expect(report.overflowRegionIDs.isEmpty)
    #expect(report.supplementedRegionIDs.contains("first"))
    let completed = try #require(PDFDocument(url: layoutOutput))
    #expect(completed.pageCount > 3)
    #expect(completed.string?.contains("FIRST END") == true)
    try PDFLayoutTranslation.pairOriginalAndTranslation(inputURL: source, outputURL: layoutOutput)
    let paired = try #require(PDFDocument(url: layoutOutput))
    #expect(paired.pageCount == completed.pageCount)
    #expect(paired.string?.contains("FIRST END") == true)
    #expect(PDFLayoutTranslation.isSideBySideBilingual(layoutOutput))
    options.outputMode = "translated"
    let cached = try TranslationRecoveryStore.load(
      in: directory, inputURL: source, options: options)
    #expect(cached.translations == translations)
    #expect(cached.issues.isEmpty)
    let cacheAttributes = try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent(TranslationRecoveryStore.filename).path)
    #expect((cacheAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let cacheString = try String(
      contentsOf: directory.appendingPathComponent(TranslationRecoveryStore.filename),
      encoding: .utf8)
    #expect(!cacheString.contains(source.path))
    #expect(!cacheString.lowercased().contains("apikey"))

    // This entry point takes neither credentials nor a provider sender.
    let output = directory.appendingPathComponent("recovered.pdf")
    let result = try NativeDocumentProcessor.renderRecoveredTranslation(cached, to: output)
    #expect(result.logs.contains { $0.contains("未再次调用") })
    let pdf = try #require(PDFDocument(url: output))
    let allText = pdf.string ?? ""
    let normalized = allText.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(normalized.components(separatedBy: "word").count - 1 == 650)
    #expect(normalized.contains("FIRST END"))
    #expect(normalized.contains("SECOND COMPLETE"))
    #expect(normalized.contains("LAST COMPLETE"))
    #expect(!allText.contains("SOURCE"))
    let firstEnd = try #require(normalized.range(of: "FIRST END"))
    let second = try #require(normalized.range(of: "SECOND COMPLETE"))
    #expect(firstEnd.lowerBound < second.lowerBound)
    #expect(pdf.pageCount > 3)
    let pageStrings = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
    #expect(pageStrings.contains { $0.contains("原文第 2 页") && $0.contains("本页没有") })
    #expect(pageStrings.last?.contains("原文第 3 页") == true)
  }

  @Test(arguments: ["provider", "sourceLanguage", "targetLanguage", "glossary"])
  func rejectsChangedTranslationOptions(field: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try fixture(source)
    let document = try document(source)
    try TranslationRecoveryStore.save(document, in: directory)
    var options = JobOptions()
    switch field {
    case "provider": options.provider = "openai"
    case "sourceLanguage": options.sourceLanguage = "de"
    case "targetLanguage": options.targetLanguage = "fr"
    default: options.glossary = "test=测试"
    }
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.load(in: directory, inputURL: source, options: options)
    }
  }

  @Test
  func hashesCompleteInputAndRejectsMutationBeforeSaveOrRendering() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try fixture(source)
    let writer = try FileHandle(forWritingTo: source)
    let originalLength = try writer.seekToEnd()
    try writer.write(contentsOf: Data(repeating: 32, count: 300_000))
    try writer.close()
    let document = try document(source)
    try TranslationRecoveryStore.save(document, in: directory)
    // A change outside the first/last 64 KiB must still invalidate the complete-input binding.
    let mutation = try FileHandle(forWritingTo: source)
    try mutation.seek(toOffset: originalLength + 150_000)
    try mutation.write(contentsOf: Data([9]))
    try mutation.close()
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.load(in: directory, inputURL: source, options: JobOptions())
    }
    #expect(throws: (any Error).self) { try TranslationRecoveryStore.save(document, in: directory) }
    let output = directory.appendingPathComponent("recovered.pdf")
    #expect(throws: (any Error).self) {
      try NativeDocumentProcessor.renderRecoveredTranslation(document, to: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.path))
    #expect(throws: (any Error).self) {
      try NativeDocumentProcessor.finishLayoutTranslation(
        input: source, options: JobOptions(), pageCount: 1, regions: document.regions,
        translations: document.translations, outputURL: output,
        expectedSourceSHA256: document.sourceSHA256)
    }
  }

  @Test(arguments: ["checksum", "version", "missing", "duplicate", "page", "bounds", "overflow"])
  func rejectsCorruptAndSemanticallyInvalidCache(kind: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try fixture(source)
    try TranslationRecoveryStore.save(document(source), in: directory)
    let cache = directory.appendingPathComponent(TranslationRecoveryStore.filename)
    var envelope = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
    var payload = try #require(envelope["document"] as? [String: Any])
    var regions = try #require(payload["regions"] as? [[String: Any]])
    switch kind {
    case "checksum": payload["translations"] = ["first": "TAMPERED TRANSLATION"]
    case "version": payload["schemaVersion"] = 1
    case "missing": payload["translations"] = [String: String]()
    case "duplicate": regions.append(regions[0])
    case "page": regions[0]["pageIndex"] = 1
    case "bounds": regions[0]["bounds"] = [[0, 0], [-1, 10]]
    default: payload["overflowRegionIDs"] = ["missing-region"]
    }
    payload["regions"] = regions
    envelope["document"] = payload
    if kind != "checksum" {
      // Recomputed checksums cannot bypass independent semantic validation.
      let decoded = try JSONDecoder().decode(
        TranslationRecoveryDocument.self, from: JSONSerialization.data(withJSONObject: payload))
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      envelope["digest"] = SHA256.hash(data: try encoder.encode(decoded))
        .map { String(format: "%02x", $0) }.joined()
    }
    try JSONSerialization.data(withJSONObject: envelope).write(to: cache)
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.load(in: directory, inputURL: source, options: JobOptions())
    }
  }

  @Test(arguments: ["oversized", "symlink", "hardlink", "fifo", "directory"])
  func rejectsUnsafeCacheFiles(kind: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try fixture(source)
    let cached = try document(source)
    let cache = directory.appendingPathComponent(TranslationRecoveryStore.filename)
    switch kind {
    case "oversized":
      try Data().write(to: cache)
      let handle = try FileHandle(forWritingTo: cache)
      try handle.truncate(atOffset: UInt64(TranslationRecoveryStore.maximumBytes + 1))
      try handle.close()
    case "symlink":
      try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: source)
    case "hardlink": try FileManager.default.linkItem(at: source, to: cache)
    case "fifo": #expect(mkfifo(cache.path, 0o600) == 0)
    default: try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false)
    }
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.load(in: directory, inputURL: source, options: JobOptions())
    }
    if kind != "oversized" {
      #expect(throws: (any Error).self) { try TranslationRecoveryStore.save(cached, in: directory) }
    }
  }

  @Test
  func rejectsInputAndAncestorSymlinks() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try fixture(source)
    let document = try document(source)
    try TranslationRecoveryStore.save(document, in: directory)
    let sourceLink = directory.appendingPathComponent("linked.pdf")
    try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.load(in: directory, inputURL: sourceLink, options: JobOptions())
    }
    let directoryLink = directory.appendingPathComponent("linked-directory")
    try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: directory)
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.load(in: directoryLink, inputURL: source, options: JobOptions())
    }
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.save(document, in: directoryLink)
    }
  }

  @Test(arguments: ["origin", "size", "font", "pageCount"])
  func rejectsNonfiniteGeometryAndMismatchedPDFPageCount(kind: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.pdf")
    try fixture(source)
    let region = PDFTranslationRegion(
      id: "invalid", pageIndex: 0, kind: .nativeText,
      bounds: CGRect(
        x: kind == "origin" ? CGFloat.nan : 30, y: 120,
        width: kind == "size" ? CGFloat.infinity : 60, height: 14),
      sourceText: "SOURCE TEXT", preferredFontSize: kind == "font" ? .infinity : 12)
    #expect(throws: (any Error).self) {
      try TranslationRecoveryStore.create(
        inputURL: source, options: JobOptions(), pageCount: kind == "pageCount" ? 2 : 1,
        regions: [region], translations: [region.id: "COMPLETE TRANSLATION"], overflowRegionIDs: [])
    }
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Transall-Recovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func region(_ id: String, page: Int) -> PDFTranslationRegion {
    PDFTranslationRegion(
      id: id, pageIndex: page, kind: .nativeText,
      bounds: CGRect(x: 30, y: 120, width: 60, height: 14), sourceText: "SOURCE TEXT",
      preferredFontSize: 12)
  }

  private func document(_ source: URL) throws -> TranslationRecoveryDocument {
    try TranslationRecoveryStore.create(
      inputURL: source, options: JobOptions(), pageCount: 1,
      regions: [region("first", page: 0)], translations: ["first": "COMPLETE TRANSLATION"],
      overflowRegionIDs: ["first"])
  }

  private func fixture(_ url: URL, pageCount: Int = 1) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
    let consumer = try #require(CGDataConsumer(url: url as CFURL))
    let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
    for _ in 0..<pageCount {
      context.beginPDFPage(nil)
      context.setFillColor(NSColor.white.cgColor)
      context.fill(mediaBox)
      let line = CTLineCreateWithAttributedString(
        NSAttributedString(
          string: "SOURCE TEXT", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
      context.textPosition = CGPoint(x: 30, y: 120)
      CTLineDraw(line, context)
      context.endPDFPage()
    }
    context.closePDF()
  }
}
