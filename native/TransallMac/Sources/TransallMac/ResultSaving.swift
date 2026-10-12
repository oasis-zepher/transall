import CryptoKit
import Foundation

struct CompletedResultFingerprint: Equatable, Sendable {
  let byteCount: Int64
  let sampleSHA256: String
}

enum SecureFileTransfer {
  static func openRegularSource(
    _ source: URL, nonRegularMessage: String
  ) throws -> (handle: FileHandle, status: stat) {
    var openError = Int32(EINVAL)
    let descriptor = source.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      let result = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
      if result < 0 { openError = errno }
      return result
    }
    guard descriptor >= 0 else {
      if openError == ELOOP {
        throw NativeDocumentError.invalidFile(nonRegularMessage)
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
    }

    do {
      let status = try fileStatus(for: descriptor)
      guard isRegularFile(status), status.st_size >= 0 else {
        throw NativeDocumentError.invalidFile(nonRegularMessage)
      }
      return (FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), status)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
  }

  static func openNewDestination(_ destination: URL) throws -> FileHandle {
    var openError = Int32(EINVAL)
    let descriptor = destination.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      let result = Darwin.open(
        path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
        mode_t(S_IRUSR | S_IWUSR))
      if result < 0 { openError = errno }
      return result
    }
    guard descriptor >= 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(openError))
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }

  static func fileStatus(for descriptor: Int32) throws -> stat {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return status
  }

  static func isRegularFile(_ status: stat) -> Bool {
    (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
  }

  static func isUnchanged(_ initial: stat, _ final: stat) -> Bool {
    isRegularFile(final) && initial.st_dev == final.st_dev && initial.st_ino == final.st_ino
      && initial.st_size == final.st_size
      && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
      && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
      && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
      && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
  }
}

enum AtomicResultSaver {
  static func copyReplacing(
    source: URL, destination: URL, chunkSize: Int = 1_024 * 1_024,
    expectedFingerprint: CompletedResultFingerprint? = nil,
    allowReplacingExistingDestination: Bool = true
  ) throws {
    guard source.isFileURL, destination.isFileURL else {
      throw ResultSaveError.invalidDestination
    }
    guard chunkSize > 0 else {
      throw NativeDocumentError.invalidFile("结果保存分块大小无效。")
    }
    let manager = FileManager.default
    if !allowReplacingExistingDestination, manager.fileExists(atPath: destination.path) {
      throw ResultSaveError.restoredTaskExistingDestination
    }
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".transall-save-\(UUID().uuidString)", isDirectory: false)
    var removeTemporary = true
    defer {
      if removeTemporary {
        try? manager.removeItem(at: temporary)
      }
    }

    try Task.checkCancellation()
    let (sourceHandle, initialSourceStatus) = try SecureFileTransfer.openRegularSource(
      source, nonRegularMessage: "任务结果不是有效的普通文件。")
    defer { try? sourceHandle.close() }

    let destinationHandle = try SecureFileTransfer.openNewDestination(temporary)
    var destinationClosed = false
    defer {
      if !destinationClosed { try? destinationHandle.close() }
    }

    var copiedBytes: Int64 = 0
    let sampleSize = 64 * 1_024
    var smallResultSample = Data()
    var firstSample = Data()
    var lastSample = Data()
    var canUseCompleteSample = true
    while true {
      try Task.checkCancellation()
      guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
        break
      }
      try Task.checkCancellation()
      let (newTotal, overflow) = copiedBytes.addingReportingOverflow(Int64(chunk.count))
      guard !overflow else {
        throw NativeDocumentError.invalidFile("任务结果过大，无法保存。")
      }
      if expectedFingerprint != nil {
        if canUseCompleteSample, newTotal <= Int64(sampleSize * 2) {
          smallResultSample.append(chunk)
        } else {
          canUseCompleteSample = false
          smallResultSample.removeAll(keepingCapacity: false)
        }
        if firstSample.count < sampleSize {
          firstSample.append(chunk.prefix(sampleSize - firstSample.count))
        }
        if chunk.count >= sampleSize {
          lastSample = Data(chunk.suffix(sampleSize))
        } else {
          lastSample.append(chunk)
          if lastSample.count > sampleSize {
            lastSample.removeFirst(lastSample.count - sampleSize)
          }
        }
      }
      try destinationHandle.write(contentsOf: chunk)
      copiedBytes = newTotal
      try Task.checkCancellation()
    }
    if let expectedFingerprint {
      var sample = canUseCompleteSample ? smallResultSample : firstSample
      if !canUseCompleteSample { sample.append(lastSample) }
      let digest = SHA256.hash(data: sample).map { String(format: "%02x", $0) }.joined()
      let actual = CompletedResultFingerprint(
        byteCount: copiedBytes, sampleSHA256: digest)
      guard actual == expectedFingerprint else {
        throw NativeDocumentError.invalidFile(
          "任务结果与完成凭据不一致，未保存结果。请重新运行任务。")
      }
    }
    try destinationHandle.synchronize()
    try Task.checkCancellation()

    let finalSourceStatus = try SecureFileTransfer.fileStatus(for: sourceHandle.fileDescriptor)
    let copiedStatus = try SecureFileTransfer.fileStatus(
      for: destinationHandle.fileDescriptor)
    guard SecureFileTransfer.isUnchanged(initialSourceStatus, finalSourceStatus),
      finalSourceStatus.st_size == copiedBytes
    else {
      throw NativeDocumentError.invalidFile("任务结果在保存期间发生变化，请重新保存。")
    }
    guard SecureFileTransfer.isRegularFile(copiedStatus), copiedStatus.st_size == copiedBytes
    else {
      throw NativeDocumentError.invalidFile("结果副本保存不完整，请重试。")
    }

    try destinationHandle.close()
    destinationClosed = true
    try Task.checkCancellation()
    if allowReplacingExistingDestination {
      if manager.fileExists(atPath: destination.path) {
        _ = try manager.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try manager.moveItem(at: temporary, to: destination)
      }
    } else {
      try moveExclusively(temporary, to: destination)
    }
    removeTemporary = false
  }

  private static func moveExclusively(_ source: URL, to destination: URL) throws {
    var renameError = Int32(EINVAL)
    let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
      guard let sourcePath else { return -1 }
      return destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
        guard let destinationPath else { return -1 }
        let result = renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
        if result < 0 { renameError = errno }
        return result
      }
    }
    guard result == 0 else {
      if renameError == EEXIST {
        throw ResultSaveError.restoredTaskExistingDestination
      }
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(renameError))
    }
  }
}

enum ResultSavePolicy {
  static let panelMessage =
    "处理过程不会修改原始文件；不能把结果存回本次任务的原文件。恢复的任务只能保存为新文件。替换其他已有文件时，macOS 会先要求确认。"

  static func validate(destination: URL, originalDocuments: [SelectedDocument]?) throws {
    guard destination.isFileURL else {
      throw ResultSaveError.invalidDestination
    }
    guard let originalDocuments else {
      if FileManager.default.fileExists(atPath: destination.path) {
        throw ResultSaveError.restoredTaskExistingDestination
      }
      return
    }
    for document in originalDocuments where refersToSameFile(destination, document.url) {
      throw ResultSaveError.originalFile
    }
  }

  private static func refersToSameFile(_ first: URL, _ second: URL) -> Bool {
    let firstResolved = first.standardizedFileURL.resolvingSymlinksInPath()
    let secondResolved = second.standardizedFileURL.resolvingSymlinksInPath()
    if firstResolved.path == secondResolved.path { return true }

    let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    guard
      let firstIdentifier = try? firstResolved.resourceValues(forKeys: keys)
        .fileResourceIdentifier as? AnyHashable,
      let secondIdentifier = try? secondResolved.resourceValues(forKeys: keys)
        .fileResourceIdentifier as? AnyHashable
    else { return false }
    return firstIdentifier == secondIdentifier
  }
}

enum ResultSaveError: LocalizedError {
  case invalidDestination
  case originalFile
  case restoredTaskExistingDestination

  var errorDescription: String? {
    switch self {
    case .invalidDestination:
      "只能把结果保存为本机文件。"
    case .originalFile:
      "不能覆盖本次任务的原始文件。请选择其他位置或文件名。"
    case .restoredTaskExistingDestination:
      "恢复的任务无法确认原文件身份，不能替换已有文件。请选择新文件名或其他空位置。"
    }
  }
}
