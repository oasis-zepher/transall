import Foundation

enum PreviewCache {
  static func pages(pdfURL: URL, directory: URL, limit: Int = 8) async throws -> [URL] {
    let generation = Task.detached(priority: .userInitiated) {
      try cachedPages(pdfURL: pdfURL, directory: directory, limit: limit)
    }
    return try await withTaskCancellationHandler(
      operation: { try await generation.value },
      onCancel: { generation.cancel() })
  }

  private static func cachedPages(pdfURL: URL, directory: URL, limit: Int) throws -> [URL] {
    try Task.checkCancellation()
    try discardUnsafeCacheEntry(at: directory)
    let expectedCount = try NativeDocumentProcessor.previewPageCount(
      pdfURL: pdfURL, limit: limit)
    guard expectedCount > 0 else {
      try? FileManager.default.removeItem(at: directory)
      return []
    }

    let existing = previewFiles(in: directory)
    if isComplete(existing, expectedCount: expectedCount) {
      return existing
    }

    try discardCache(at: directory)
    do {
      let generated = try NativeDocumentProcessor.makePreviews(
        pdfURL: pdfURL, directory: directory, limit: limit)
      guard isComplete(generated, expectedCount: expectedCount) else {
        throw NativeDocumentError.processing("PDF 预览生成不完整，请重试。")
      }
      return generated
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  private static func previewFiles(in directory: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])) ?? [])
      .filter { $0.pathExtension.lowercased() == "png" }
      .sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
      }
  }

  private static func isComplete(_ urls: [URL], expectedCount: Int) -> Bool {
    guard urls.count == expectedCount else { return false }
    return urls.enumerated().allSatisfy { index, url in
      guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
        return false
      }
      guard
        let values = try? url.resourceValues(
          forKeys: [.isRegularFileKey])
      else { return false }
      return url.lastPathComponent == "page-\(index + 1).png"
        && values.isRegularFile == true
        && NativeDocumentProcessor.isReadableImage(url)
    }
  }

  private static func discardUnsafeCacheEntry(at directory: URL) throws {
    let manager = FileManager.default
    if (try? manager.destinationOfSymbolicLink(atPath: directory.path)) != nil {
      try manager.removeItem(atPath: directory.path)
      return
    }
    var isDirectory = ObjCBool(false)
    if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue
    {
      try manager.removeItem(atPath: directory.path)
    }
  }

  private static func discardCache(at directory: URL) throws {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    try FileManager.default.removeItem(at: directory)
  }
}
