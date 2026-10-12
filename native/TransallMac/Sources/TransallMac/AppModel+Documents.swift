import SwiftUI

extension AppModel {
  @discardableResult
  func receiveDroppedDocuments(_ urls: [URL]) -> Bool {
    guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
      errorMessage = "请拖入本机文件。"
      return false
    }
    guard canEditTaskDraft, !isImporting else {
      errorMessage = taskDraftLockMessage ?? "正在读取文件，请稍后再拖入。"
      return false
    }
    if route == nil {
      // On the empty hourglass, infer only a supported route for this batch.
      // Existing source/target choices constrain the inference.
      let candidates = (capabilities?.routes ?? []).filter { route in
        let suffixes = Set(
          route.accept.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
              .lowercased()
          })
        return route.enabled && (selection.source == nil || selection.source == route.source)
          && (selection.target == nil || selection.target == route.target)
          && urls.allSatisfy { suffixes.contains($0.pathExtension.lowercased()) }
      }
      guard let route = candidates.first(where: { $0.target == "pdf" }) ?? candidates.first else {
        errorMessage = "这些文件无法用于当前格式组合，请选择匹配的源格式和目标格式。"
        return false
      }
      selection = RouteSelection(source: route.source, target: route.target)
    }
    startDocumentImport(urls, appending: !documents.isEmpty)
    return isImporting
  }

  func startDocumentImport(_ urls: [URL], appending: Bool = false) {
    guard !urls.isEmpty else {
      errorMessage = "没有选择文件。"
      return
    }
    guard documentImportTask == nil, !isImporting else { return }
    guard canEditTaskDraft else {
      errorMessage = taskDraftLockMessage.map { "\($0)。" } ?? "当前无法修改文件和参数。"
      return
    }
    guard route?.enabled == true else {
      errorMessage = "请先选择源格式和目标格式。"
      return
    }

    isImporting = true
    errorMessage = nil
    documentImportTask = Task { [weak self] in
      guard let self else { return }
      defer {
        isImporting = false
        documentImportTask = nil
      }
      await performDocumentImport(urls, appending: appending)
    }
  }

  func importDocuments(_ urls: [URL], appending: Bool = false) async {
    startDocumentImport(urls, appending: appending)
    guard let documentImportTask else { return }
    await documentImportTask.value
  }

  func requestDocumentImportCancellation() {
    documentImportTask?.cancel()
  }

  func cancelDocumentImport() async {
    guard let documentImportTask else { return }
    documentImportTask.cancel()
    await documentImportTask.value
  }

  private func performDocumentImport(_ urls: [URL], appending: Bool) async {
    guard !Task.isCancelled else { return }

    var seenURLs = Set(
      (appending ? documents : []).map { $0.url.standardizedFileURL })
    let uniqueURLs = urls.filter {
      seenURLs.insert($0.standardizedFileURL).inserted
    }
    guard seenURLs.count <= NativeCapabilities.maximumInputFileCount else {
      errorMessage =
        "每批最多选择 \(NativeCapabilities.maximumInputFileCount) 个文件，请分批处理。"
      return
    }

    let imported: [SelectedDocument]
    do {
      imported = try await documentInspector(uniqueURLs)
      try Task.checkCancellation()
    } catch is CancellationError {
      return
    } catch {
      guard !Task.isCancelled else { return }
      errorMessage = error.localizedDescription
      return
    }

    var combined = appending ? documents : []
    var existing = Set(combined.map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
    combined.append(
      contentsOf: imported.filter {
        existing.insert($0.url.standardizedFileURL.resolvingSymlinksInPath()).inserted
      })
    guard combined.count <= NativeCapabilities.maximumInputFileCount else {
      errorMessage =
        "每批最多选择 \(NativeCapabilities.maximumInputFileCount) 个文件，请分批处理。"
      return
    }

    if let route {
      let extensions = Set(
        route.accept.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
            .lowercased()
        })
      if let invalid = combined.first(where: {
        !extensions.contains($0.url.pathExtension.lowercased())
      }) {
        errorMessage = "\(invalid.name)：当前任务接受 \(route.accept)。"
        return
      }
    }

    let total = combined.reduce(Int64.zero) { partial, document in
      let (sum, overflow) = partial.addingReportingOverflow(document.size)
      return overflow ? Int64.max : sum
    }
    let limitBytes =
      route.map(NativeCapabilities.inputLimitBytes(for:))
      ?? capabilities?.limits.maxUploadBytes ?? NativeCapabilities.uploadLimitBytes
    if total > Int64(limitBytes) {
      errorMessage = "所选文件超过 \(inputLimitMB) MB 限制。"
      return
    }
    guard !Task.isCancelled else { return }
    // Import edits the next submission's draft. Keep the displayed result, its
    // preview and submitted-original identities available until a new job exists.
    documents = combined
    errorMessage = nil
  }

  nonisolated static func inspectDocuments(_ urls: [URL]) throws
    -> [SelectedDocument]
  {
    let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
    var imported: [SelectedDocument] = []
    var failures: [String] = []

    for url in urls {
      try Task.checkCancellation()
      let accessing = url.startAccessingSecurityScopedResource()
      defer { if accessing { url.stopAccessingSecurityScopedResource() } }
      do {
        let values = try url.resourceValues(forKeys: keys)
        if values.isSymbolicLink == true {
          failures.append("\(url.lastPathComponent)：不支持符号链接，请选择原始文件。")
        } else if values.isRegularFile != true {
          failures.append("\(url.lastPathComponent)：不是普通文件。")
        } else if let size = values.fileSize {
          imported.append(SelectedDocument(url: url, size: Int64(size)))
        } else {
          failures.append("\(url.lastPathComponent)：无法读取文件大小。")
        }
      } catch {
        failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
      }
    }

    guard failures.isEmpty else { throw DocumentImportError(failures: failures) }
    return imported
  }

  func removeDocument(_ document: SelectedDocument) {
    guard !isImporting, canEditTaskDraft else { return }
    documents.removeAll { $0.id == document.id }
  }
}
