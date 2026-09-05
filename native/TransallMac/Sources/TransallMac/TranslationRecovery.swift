import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PDFKit

struct TranslationLayoutIssue: Identifiable, Codable, Sendable, Equatable {
  let id: String
  let pageIndex: Int
  let bounds: CGRect
  let sourceText: String
  let translatedText: String
}

struct TranslationRecoveryDocument: Codable, Sendable {
  let schemaVersion: Int
  let sourceSHA256: String
  let pageCount: Int
  let provider: String
  let sourceLanguage: String
  let targetLanguage: String
  let glossary: String
  let regions: [PDFTranslationRegion]
  let translations: [String: String]
  var overflowRegionIDs: [String]

  // Bound only by create/load. Neither paths nor credentials are persisted in the cache.
  fileprivate var sourceURL: URL? = nil

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, sourceSHA256, pageCount, provider, sourceLanguage, targetLanguage
    case glossary, regions, translations, overflowRegionIDs
  }

  var issues: [TranslationLayoutIssue] {
    let overflow = Set(overflowRegionIDs)
    return regions.compactMap { region in
      guard overflow.contains(region.id), let translatedText = translations[region.id] else {
        return nil
      }
      return TranslationLayoutIssue(
        id: region.id, pageIndex: region.pageIndex, bounds: region.bounds,
        sourceText: region.sourceText, translatedText: translatedText)
    }
  }
}

enum TranslationRecoveryStore {
  static let filename = "translation-recovery.json"
  static let maximumBytes = 32 * 1_024 * 1_024
  static let schemaVersion = 1

  private struct Envelope: Codable {
    let document: TranslationRecoveryDocument
    let digest: String
  }

  static func create(
    inputURL: URL, options: JobOptions, pageCount: Int,
    regions: [PDFTranslationRegion], translations: [String: String],
    overflowRegionIDs: [String]
  ) throws -> TranslationRecoveryDocument {
    var document = TranslationRecoveryDocument(
      schemaVersion: schemaVersion, sourceSHA256: try sourceFingerprint(inputURL: inputURL),
      pageCount: pageCount, provider: options.provider, sourceLanguage: options.sourceLanguage,
      targetLanguage: options.targetLanguage, glossary: options.glossary,
      regions: regions, translations: translations, overflowRegionIDs: overflowRegionIDs)
    document.sourceURL = inputURL
    try validateContents(document)
    try validateSourcePageCount(document)
    try validateSource(document)
    return document
  }

  static func save(_ document: TranslationRecoveryDocument, in directory: URL) throws {
    try validateForRendering(document)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let payload = try encoder.encode(document)
    guard payload.count <= maximumBytes else { throw invalid("译文缓存超过 32 MB 限制。") }
    let data = try encoder.encode(Envelope(document: document, digest: digest(payload)))
    guard data.count <= maximumBytes else { throw invalid("译文缓存超过 32 MB 限制。") }

    let directoryFD = try openDirectory(directory)
    defer { Darwin.close(directoryFD) }
    try validateExistingCache(in: directoryFD)
    let temporaryName = ".translation-recovery-\(UUID().uuidString)"
    let descriptor = openat(
      directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      mode_t(S_IRUSR | S_IWUSR))
    guard descriptor >= 0 else { throw posixError() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer {
      try? handle.close()
      unlinkat(directoryFD, temporaryName, 0)
    }
    try handle.write(contentsOf: data)
    try handle.synchronize()
    let savedStatus = try status(descriptor)
    guard isRegular(savedStatus), savedStatus.st_size == data.count else {
      throw invalid("译文缓存写入不完整。")
    }
    // Hash again after writing, so a replaced or changed submitted input never gains a cache.
    try validateSource(document)
    try Task.checkCancellation()
    try validateExistingCache(in: directoryFD)
    var temporaryStatus = stat()
    guard fstatat(directoryFD, temporaryName, &temporaryStatus, AT_SYMLINK_NOFOLLOW) == 0,
      unchanged(savedStatus, temporaryStatus), temporaryStatus.st_nlink == 1
    else { throw invalid("译文缓存临时文件在保存期间发生变化。") }
    guard renameat(directoryFD, temporaryName, directoryFD, filename) == 0 else {
      throw posixError()
    }
    guard fsync(directoryFD) == 0 else { throw posixError() }
  }

  static func load(in directory: URL, inputURL: URL, options: JobOptions) throws
    -> TranslationRecoveryDocument
  {
    let directoryFD = try openDirectory(directory)
    defer { Darwin.close(directoryFD) }
    let descriptor = openat(directoryFD, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw invalid("无法读取已保存的译文，请重新检查任务。") }
    let data = try boundedData(descriptor: descriptor, maximumBytes: maximumBytes)
    let envelope: Envelope
    do {
      envelope = try JSONDecoder().decode(Envelope.self, from: data)
    } catch {
      throw invalid("译文缓存格式损坏，无法继续导出。")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard digest(try encoder.encode(envelope.document)) == envelope.digest else {
      throw invalid("译文缓存校验失败，内容可能已经发生变化。")
    }
    var document = envelope.document
    document.sourceURL = inputURL
    try validateContents(document)
    guard document.provider == options.provider,
      document.sourceLanguage == options.sourceLanguage,
      document.targetLanguage == options.targetLanguage, document.glossary == options.glossary
    else { throw invalid("已保存的译文与当前翻译服务、语言或术语表不一致。") }
    try validateSource(document)
    try validateSourcePageCount(document)
    try validateSource(document)
    return document
  }

  static func sourceFingerprint(inputURL: URL) throws -> String {
    guard inputURL.isFileURL else { throw invalid("译文缓存的输入地址无效。") }
    let directoryFD = try openDirectory(inputURL.deletingLastPathComponent())
    defer { Darwin.close(directoryFD) }
    let descriptor = openat(
      directoryFD, inputURL.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw invalid("无法安全读取译文对应的输入文件。") }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    let initial = try status(descriptor)
    guard isRegular(initial), initial.st_size > 0,
      initial.st_size <= NativeCapabilities.uploadLimitBytes
    else { throw invalid("译文缓存的输入不是有效文件，或超过文件大小限制。") }
    var hasher = SHA256()
    var byteCount: Int64 = 0
    while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
      try Task.checkCancellation()
      byteCount += Int64(chunk.count)
      guard byteCount <= NativeCapabilities.uploadLimitBytes else {
        throw invalid("译文缓存的输入超过文件大小限制。")
      }
      hasher.update(data: chunk)
    }
    let final = try status(descriptor)
    var pathStatus = stat()
    guard fstatat(directoryFD, inputURL.lastPathComponent, &pathStatus, AT_SYMLINK_NOFOLLOW) == 0,
      unchanged(initial, final), unchanged(initial, pathStatus), final.st_size == byteCount
    else { throw invalid("输入文件在读取期间发生变化，无法复用译文。") }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  static func validateForRendering(_ document: TranslationRecoveryDocument) throws {
    try validateContents(document)
    try validateSource(document)
  }

  private static func validateSource(_ document: TranslationRecoveryDocument) throws {
    guard let inputURL = document.sourceURL,
      try sourceFingerprint(inputURL: inputURL) == document.sourceSHA256
    else { throw invalid("输入文件与已保存译文不一致，无法复用译文。") }
  }

  private static func validateSourcePageCount(_ document: TranslationRecoveryDocument) throws {
    // Callers verify the complete input hash before and after this pathname-based PDF parser.
    guard let inputURL = document.sourceURL, let pdf = CGPDFDocument(inputURL as CFURL),
      pdf.numberOfPages == document.pageCount
    else { throw invalid("输入 PDF 页数与已保存译文不一致。") }
  }

  private static func validateContents(_ document: TranslationRecoveryDocument) throws {
    guard document.schemaVersion == schemaVersion,
      document.sourceSHA256.count == 64,
      document.sourceSHA256.allSatisfy({ "0123456789abcdef".contains($0) }),
      (1...PDFTranslationPolicy.maximumPages).contains(document.pageCount),
      !document.regions.isEmpty, document.regions.count <= PDFLayoutTranslation.maximumRegions,
      document.translations.count == document.regions.count,
      document.overflowRegionIDs.count <= document.regions.count,
      ["openai", "deepseek"].contains(document.provider),
      !document.sourceLanguage.isEmpty, document.sourceLanguage.count <= 80,
      !document.targetLanguage.isEmpty, document.targetLanguage.count <= 80,
      document.glossary.count <= TranslationService.maximumGlossaryCharacters
    else { throw invalid("译文缓存版本或文档信息无效。") }
    let identifiers = Set(document.regions.map(\.id))
    guard identifiers.count == document.regions.count,
      Set(document.translations.keys) == identifiers,
      Set(document.overflowRegionIDs).count == document.overflowRegionIDs.count,
      Set(document.overflowRegionIDs).isSubset(of: identifiers)
    else { throw invalid("译文缓存的区域标识或译文对应关系无效。") }
    var sourceCharacters = 0
    var textBytes = 0
    for region in document.regions {
      try Task.checkCancellation()
      let bounds = region.bounds
      guard !region.id.isEmpty, region.id.count <= 128,
        (0..<document.pageCount).contains(region.pageIndex),
        [
          bounds.origin.x, bounds.origin.y, bounds.width, bounds.height,
          bounds.maxX, bounds.maxY, region.preferredFontSize,
        ].allSatisfy({ $0.isFinite }),
        bounds.size.width > 0, bounds.size.height > 0,
        abs(bounds.origin.x) <= 1_000_000, abs(bounds.origin.y) <= 1_000_000,
        bounds.width <= 1_000_000, bounds.height <= 1_000_000,
        region.preferredFontSize > 0, region.preferredFontSize <= 10_000,
        !region.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let translation = document.translations[region.id],
        !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        translation.count <= TranslationService.maximumTranslatedCharacters(for: region.sourceText)
      else { throw invalid("译文缓存包含无效区域、页码或译文。") }
      sourceCharacters = try PDFTranslationPolicy.totalCharacters(
        afterAdding: region.sourceText.count, to: sourceCharacters)
      textBytes += region.sourceText.utf8.count + translation.utf8.count
      guard textBytes <= maximumBytes * 3 / 4 else {
        throw invalid("译文缓存中的文字超过大小限制。")
      }
    }
  }

  private static func boundedData(descriptor: Int32, maximumBytes: Int) throws -> Data {
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    let initial = try status(descriptor)
    guard isRegular(initial), initial.st_size > 0, initial.st_size <= maximumBytes,
      initial.st_nlink == 1
    else { throw invalid("译文缓存不是普通文件，或超过 32 MB 限制。") }
    var data = Data()
    data.reserveCapacity(Int(initial.st_size))
    while let chunk = try handle.read(upToCount: min(64 * 1_024, maximumBytes - data.count + 1)),
      !chunk.isEmpty
    {
      try Task.checkCancellation()
      guard chunk.count <= maximumBytes - data.count else {
        throw invalid("译文缓存超过 32 MB 限制。")
      }
      data.append(chunk)
    }
    guard unchanged(initial, try status(descriptor)), data.count == initial.st_size else {
      throw invalid("译文缓存在读取期间发生变化。")
    }
    return data
  }

  private static func openDirectory(_ url: URL) throws -> Int32 {
    guard url.isFileURL else { throw invalid("译文缓存目录无效。") }
    var components = Array(url.standardizedFileURL.pathComponents.dropFirst())
    // macOS exposes /var and /tmp as system aliases. Other symlink components are rejected.
    if let first = components.first, first == "var" || first == "tmp" {
      components.insert("private", at: 0)
    }
    var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw posixError() }
    for component in components {
      let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      Darwin.close(descriptor)
      guard next >= 0 else { throw invalid("译文缓存目录不存在或包含符号链接。") }
      descriptor = next
    }
    return descriptor
  }

  private static func validateExistingCache(in directoryFD: Int32) throws {
    var existing = stat()
    let result = fstatat(directoryFD, filename, &existing, AT_SYMLINK_NOFOLLOW)
    if result < 0 {
      guard errno == ENOENT else { throw posixError() }
    } else if !isRegular(existing) || existing.st_nlink != 1 {
      throw invalid("译文缓存地址已被其他文件或链接占用。")
    }
  }

  private static func status(_ descriptor: Int32) throws -> stat {
    var value = stat()
    guard fstat(descriptor, &value) == 0 else { throw posixError() }
    return value
  }

  private static func isRegular(_ value: stat) -> Bool {
    value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
  }

  private static func unchanged(_ initial: stat, _ final: stat) -> Bool {
    isRegular(final) && initial.st_dev == final.st_dev && initial.st_ino == final.st_ino
      && initial.st_size == final.st_size
      && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
      && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
      && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
      && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func invalid(_ message: String) -> NativeDocumentError {
    .invalidFile(message)
  }

  private static func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }
}
