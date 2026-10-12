import CryptoKit
import Foundation

/// Reads, writes, and validates task files under the Jobs directory.
enum JobStorage {
  static let maximumJobStateBytes = 1 * 1_024 * 1_024
  static let maximumJobMetadataBytes = 128 * 1_024
  static let maximumCompletionReceiptBytes = 16 * 1_024

  struct CleanupScan: Sendable {
    let directories: [URL]
    let warnings: [String]
  }

  static func copyInputs(
    _ files: [SelectedDocument], to inputDirectory: URL, maximumBytes: Int, maximumMB: Int,
    chunkSize: Int = 1_024 * 1_024
  ) async throws -> [URL] {
    guard maximumBytes >= 0, chunkSize > 0 else {
      throw NativeDocumentError.invalidFile("输入文件复制限制无效。")
    }
    guard files.count <= NativeCapabilities.maximumInputFileCount else {
      throw NativeDocumentError.invalidFile(
        "每批最多处理 \(NativeCapabilities.maximumInputFileCount) 个文件，请拆分为多个任务。")
    }
    let transfer = Task.detached(priority: .userInitiated) {
      var copiedInputs: [URL] = []
      var removeCopiedInputs = true
      defer {
        if removeCopiedInputs {
          for copiedInput in copiedInputs {
            try? FileManager.default.removeItem(at: copiedInput)
          }
        }
      }
      var copiedBytes: Int64 = 0
      let resourceKeys: Set<URLResourceKey> = [
        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
      ]
      for (index, document) in files.enumerated() {
        try Task.checkCancellation()
        let safeName =
          "\(index + 1)-\(document.name.replacingOccurrences(of: "/", with: "-"))"
        let destination = try containedFileURL(
          named: safeName, in: inputDirectory, description: "输入文件")
        let accessing = document.url.startAccessingSecurityScopedResource()
        defer { if accessing { document.url.stopAccessingSecurityScopedResource() } }
        do {
          let sourceValues = try document.url.resourceValues(forKeys: resourceKeys)
          guard sourceValues.isSymbolicLink != true, sourceValues.isRegularFile == true else {
            throw NativeDocumentError.invalidFile(
              "\(document.name) 不是可复制的普通文件，请选择原始文件。")
          }

          let (sourceHandle, initialSourceStatus) = try SecureFileTransfer.openRegularSource(
            document.url,
            nonRegularMessage: "\(document.name) 不是可复制的普通文件，请选择原始文件。")
          defer { try? sourceHandle.close() }

          try Task.checkCancellation()
          let sourceSize = initialSourceStatus.st_size
          let maximum = Int64(maximumBytes)
          let (expectedTotal, expectedOverflow) = copiedBytes.addingReportingOverflow(sourceSize)
          guard !expectedOverflow, expectedTotal <= maximum else {
            throw NativeDocumentError.invalidFile(
              "复制后的文件总计超过 \(maximumMB) MB。")
          }

          var removeIncompleteDestination = true
          defer {
            if removeIncompleteDestination {
              try? FileManager.default.removeItem(at: destination)
            }
          }
          let destinationHandle = try SecureFileTransfer.openNewDestination(destination)
          defer { try? destinationHandle.close() }

          var fileBytes: Int64 = 0
          while true {
            try Task.checkCancellation()
            guard let chunk = try sourceHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
              break
            }
            try Task.checkCancellation()
            let (newTotal, totalOverflow) = copiedBytes.addingReportingOverflow(
              Int64(chunk.count))
            guard !totalOverflow, newTotal <= maximum else {
              throw NativeDocumentError.invalidFile(
                "复制后的文件总计超过 \(maximumMB) MB。")
            }
            try destinationHandle.write(contentsOf: chunk)
            copiedBytes = newTotal
            fileBytes += Int64(chunk.count)
            try Task.checkCancellation()
            await Task.yield()
          }
          try destinationHandle.synchronize()
          try Task.checkCancellation()

          let sourceStatus = try SecureFileTransfer.fileStatus(for: sourceHandle.fileDescriptor)
          let copiedStatus = try SecureFileTransfer.fileStatus(
            for: destinationHandle.fileDescriptor)
          guard SecureFileTransfer.isUnchanged(initialSourceStatus, sourceStatus),
            sourceStatus.st_size == fileBytes
          else {
            throw NativeDocumentError.invalidFile(
              "\(document.name) 在复制过程中发生变化，请重新选择。")
          }
          guard SecureFileTransfer.isRegularFile(copiedStatus), copiedStatus.st_size == fileBytes
          else {
            throw NativeDocumentError.invalidFile(
              "\(document.name) 复制后不是有效的普通文件。")
          }
          removeIncompleteDestination = false
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as NativeDocumentError {
          throw error
        } catch {
          throw NativeDocumentError.invalidFile(
            "无法读取 \(document.name)：\(error.localizedDescription)")
        }
        copiedInputs.append(destination)
      }
      removeCopiedInputs = false
      return copiedInputs
    }
    return try await withTaskCancellationHandler(
      operation: { try await transfer.value },
      onCancel: { transfer.cancel() })
  }

  static func prepareDataDirectory(override: URL?) throws -> (
    directory: URL, warnings: [String]
  ) {
    let directory: URL
    if let override {
      directory = override
    } else {
      let base = try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      directory = base.appendingPathComponent("Transall", isDirectory: true)
    }
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("Jobs", isDirectory: true),
      withIntermediateDirectories: true)
    let jobsDirectory = directory.appendingPathComponent("Jobs", isDirectory: true)
    let scan = try expiredJobDirectories(in: jobsDirectory, now: Date())
    var warnings = scan.warnings
    for directory in scan.directories {
      try Task.checkCancellation()
      do {
        try FileManager.default.removeItem(at: directory)
      } catch {
        warnings.append("未能清理过期任务 \(directory.lastPathComponent)：\(error.localizedDescription)")
      }
    }
    return (directory, warnings)
  }

  static func expiredJobDirectories(
    in jobsDirectory: URL, now: Date
  ) throws -> CleanupScan {
    try validateDirectory(jobsDirectory, description: "任务数据目录")
    let directories = try FileManager.default.contentsOfDirectory(
      at: jobsDirectory,
      includingPropertiesForKeys: [
        .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
      ],
      options: [.skipsHiddenFiles])
    let dateFormatter = ISO8601DateFormatter()
    var expired: [URL] = []
    var warnings: [String] = []
    for directory in directories {
      try Task.checkCancellation()
      do {
        let values = try directory.resourceValues(
          forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isDirectory == true,
          let modified = values.contentModificationDate
        else { continue }
        let referenceDate = cleanupReferenceDate(
          in: directory, fallback: modified, now: now, dateFormatter: dateFormatter)
        guard now.timeIntervalSince(referenceDate) >= 24 * 60 * 60 else { continue }
        expired.append(directory)
      } catch {
        warnings.append("无法检查任务 \(directory.lastPathComponent) 的保留期：\(error.localizedDescription)")
      }
    }
    return CleanupScan(directories: expired, warnings: warnings)
  }

  static func cleanupReferenceDate(
    in directory: URL, fallback: Date, now: Date, dateFormatter: ISO8601DateFormatter
  ) -> Date {
    guard
      let data = try? boundedTaskFileData(
        named: "job.json", in: directory, description: "任务状态文件",
        maximumBytes: maximumJobStateBytes),
      let job = try? JSONDecoder().decode(JobResponse.self, from: data),
      job.id == directory.lastPathComponent,
      let createdAt = dateFormatter.date(from: job.createdAt),
      createdAt <= now.addingTimeInterval(5 * 60)
    else {
      return fallback
    }
    return createdAt
  }

  static func persistJob(_ job: JobResponse, in directory: URL) throws {
    let data = try JSONEncoder().encode(job)
    try validatePersistedDataSize(
      data, description: "任务状态", maximumBytes: maximumJobStateBytes)
    try data.write(to: directory.appendingPathComponent("job.json"), options: .atomic)
  }

  static func isCompleteResult(_ url: URL) -> Bool {
    guard
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
      values.isSymbolicLink != true, values.isRegularFile == true
    else {
      return false
    }
    if url.pathExtension.lowercased() == "pdf" {
      return ((try? NativeDocumentProcessor.previewPageCount(pdfURL: url, limit: 1)) ?? 0) > 0
    }
    return true
  }

  static func completionReceiptMatches(
    _ receipt: NativeJobCompletionReceipt, expectedOutput: String, outputURL: URL
  ) -> Bool {
    guard receipt.output == expectedOutput, let expected = fingerprint(from: receipt),
      isCompleteResult(outputURL),
      let fingerprint = try? resultFingerprint(outputURL)
    else {
      return false
    }
    return fingerprint == expected
  }

  static func validatedCompletedResult(
    named output: String, in directory: URL
  ) throws -> (url: URL, fingerprint: CompletedResultFingerprint) {
    let outputURL = try validatedRegularFile(
      named: output, in: directory, description: "任务结果")
    let receipt: NativeJobCompletionReceipt
    do {
      let data = try boundedTaskFileData(
        named: "completion.json", in: directory, description: "任务完成凭据",
        maximumBytes: maximumCompletionReceiptBytes)
      receipt = try JSONDecoder().decode(NativeJobCompletionReceipt.self, from: data)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw NativeDocumentError.invalidFile("任务完成凭据缺失或无效，请重新运行任务。")
    }
    guard receipt.output == output, let expected = fingerprint(from: receipt),
      isCompleteResult(outputURL), try resultFingerprint(outputURL) == expected
    else {
      throw NativeDocumentError.invalidFile("任务结果与完成凭据不一致，请重新运行任务。")
    }
    return (outputURL, expected)
  }

  static func fingerprint(
    from receipt: NativeJobCompletionReceipt
  ) -> CompletedResultFingerprint? {
    guard let byteCount = receipt.byteCount, byteCount >= 0,
      let sampleSHA256 = receipt.sampleSHA256, sampleSHA256.count == 64,
      sampleSHA256.allSatisfy({ $0.isHexDigit })
    else { return nil }
    return CompletedResultFingerprint(byteCount: byteCount, sampleSHA256: sampleSHA256)
  }

  static func resultFingerprint(_ url: URL) throws
    -> CompletedResultFingerprint
  {
    let sampleSize = 64 * 1_024
    let (handle, initialStatus) = try SecureFileTransfer.openRegularSource(
      url, nonRegularMessage: "任务结果不是有效的普通文件。")
    defer { try? handle.close() }
    let fileSize = initialStatus.st_size
    var sample = Data()
    if fileSize <= Int64(sampleSize * 2) {
      sample = try handle.readToEnd() ?? Data()
      guard Int64(sample.count) == fileSize else {
        throw NativeDocumentError.processing("任务结果大小在验证期间发生变化。")
      }
    } else {
      let prefix = try handle.read(upToCount: sampleSize) ?? Data()
      try handle.seek(toOffset: UInt64(fileSize - Int64(sampleSize)))
      let suffix = try handle.read(upToCount: sampleSize) ?? Data()
      guard prefix.count == sampleSize, suffix.count == sampleSize else {
        throw NativeDocumentError.processing("任务结果大小在验证期间发生变化。")
      }
      sample.append(prefix)
      sample.append(suffix)
    }
    let finalStatus = try SecureFileTransfer.fileStatus(for: handle.fileDescriptor)
    guard SecureFileTransfer.isUnchanged(initialStatus, finalStatus) else {
      throw NativeDocumentError.processing("任务结果在验证期间发生变化。")
    }
    let digest = SHA256.hash(data: sample).map { String(format: "%02x", $0) }.joined()
    return CompletedResultFingerprint(byteCount: fileSize, sampleSHA256: digest)
  }

  static func validatePersistedDataSize(
    _ data: Data, description: String, maximumBytes: Int
  ) throws {
    guard data.count <= maximumBytes else {
      throw NativeDocumentError.invalidFile("\(description)超过大小限制。")
    }
  }

  static func boundedTaskFileData(
    named name: String, in directory: URL, description: String, maximumBytes: Int
  ) throws -> Data {
    guard maximumBytes >= 0 else {
      throw NativeDocumentError.invalidFile("\(description)大小限制无效。")
    }
    let url = try containedFileURL(named: name, in: directory, description: description)
    let (handle, initialStatus) = try SecureFileTransfer.openRegularSource(
      url, nonRegularMessage: "\(description)不是有效的普通文件。")
    defer { try? handle.close() }
    guard initialStatus.st_size <= Int64(maximumBytes) else {
      throw NativeDocumentError.invalidFile("\(description)超过大小限制，数据可能已经损坏。")
    }

    var data = Data()
    data.reserveCapacity(Int(initialStatus.st_size))
    let readChunkBytes = 64 * 1_024
    while true {
      try Task.checkCancellation()
      let remaining = maximumBytes - data.count
      let requestedBytes = min(readChunkBytes, remaining + 1)
      guard let chunk = try handle.read(upToCount: requestedBytes), !chunk.isEmpty else {
        break
      }
      guard chunk.count <= remaining else {
        throw NativeDocumentError.invalidFile("\(description)超过大小限制，数据可能已经损坏。")
      }
      data.append(chunk)
    }

    let finalStatus = try SecureFileTransfer.fileStatus(for: handle.fileDescriptor)
    guard SecureFileTransfer.isUnchanged(initialStatus, finalStatus),
      finalStatus.st_size == Int64(data.count)
    else {
      throw NativeDocumentError.invalidFile("\(description)在读取期间发生变化，数据可能已经损坏。")
    }
    return data
  }

  static func validateStoredInputNames(_ names: [String]) throws {
    guard !names.isEmpty else {
      throw NativeDocumentError.invalidFile("任务没有可恢复的输入文件。")
    }
    guard names.count <= NativeCapabilities.maximumInputFileCount else {
      throw NativeDocumentError.invalidFile(
        "任务输入超过每批最多 \(NativeCapabilities.maximumInputFileCount) 个文件的限制。")
    }
    guard Set(names).count == names.count else {
      throw NativeDocumentError.invalidFile("任务输入列表包含重复文件，数据可能已经损坏。")
    }
    for name in names {
      guard isSafeFileName(name) else {
        throw NativeDocumentError.invalidFile("任务输入文件名无效，数据可能已经损坏。")
      }
    }
  }

  static func validateStoredMetadata(
    _ metadata: NativeJobMetadata, for job: JobResponse
  ) throws {
    guard canonicalRoute(matching: metadata.route) != nil, metadata.route.kind == job.kind else {
      throw NativeDocumentError.invalidFile("任务路径与任务状态不一致，数据可能已经损坏。")
    }
    try validateStoredInputNames(metadata.inputNames)
    try JobOptionValidator.validate(route: metadata.route, options: metadata.options)
    if metadata.route.kind == "pdf_edit", metadata.options.editAction == "merge",
      metadata.inputNames.count < 2
    {
      throw NativeDocumentError.invalidFile("合并 PDF 的持久化任务缺少输入文件。")
    }
    if metadata.route.kind == "pdf_edit", metadata.options.editAction != "merge",
      metadata.inputNames.count != 1
    {
      throw NativeDocumentError.invalidFile("单个 PDF 编辑任务的输入数量无效。")
    }
    if metadata.route.kind == "pdf_translate", metadata.inputNames.count != 1 {
      throw NativeDocumentError.invalidFile("PDF 翻译任务的输入数量无效。")
    }
  }

  static func canonicalRoute(
    matching route: RouteDefinition
  ) -> RouteDefinition? {
    guard route.enabled else { return nil }
    return NativeCapabilities.routes.first {
      $0.enabled && $0.source == route.source && $0.target == route.target && $0.kind == route.kind
    }
  }

  static func validatedStoredInputs(
    named names: [String], in jobDirectory: URL
  ) throws -> [URL] {
    try validateStoredInputNames(names)
    let inputDirectory = jobDirectory.appendingPathComponent("Input", isDirectory: true)
    try validateDirectory(inputDirectory, description: "任务输入目录")
    return try names.map {
      try validatedRegularFile(named: $0, in: inputDirectory, description: "任务输入")
    }
  }

  static func validatedRegularFile(
    named name: String, in directory: URL, description: String
  ) throws -> URL {
    let url = try containedFileURL(named: name, in: directory, description: description)
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    } catch {
      throw NativeDocumentError.invalidFile("\(description)不可读取：\(error.localizedDescription)")
    }
    guard values.isSymbolicLink != true, values.isRegularFile == true else {
      throw NativeDocumentError.invalidFile("\(description)不是有效的普通文件。")
    }
    return url
  }

  static func containedFileURL(
    named name: String, in directory: URL, description: String
  ) throws -> URL {
    guard isSafeFileName(name) else {
      throw NativeDocumentError.invalidFile("\(description)的文件名无效。")
    }
    let standardizedDirectory = directory.standardizedFileURL
    let url = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL
    guard url.deletingLastPathComponent() == standardizedDirectory else {
      throw NativeDocumentError.invalidFile("\(description)超出任务目录。")
    }
    return url
  }

  static func isSafeFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
      && URL(fileURLWithPath: name).lastPathComponent == name
  }

  static func validateDirectory(_ url: URL, description: String) throws {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    } catch {
      throw NativeDocumentError.invalidFile("\(description)不可读取：\(error.localizedDescription)")
    }
    guard values.isSymbolicLink != true, values.isDirectory == true else {
      throw NativeDocumentError.invalidFile("\(description)不是有效目录。")
    }
  }
}

struct NativeJobMetadata: Codable {
  let route: RouteDefinition
  let options: JobOptions
  let inputNames: [String]
}

struct NativeJobCompletionReceipt: Codable {
  let output: String
  let byteCount: Int64?
  let sampleSHA256: String?
}
