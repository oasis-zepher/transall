import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct FileDropAction: Sendable {
  var receive: (@MainActor @Sendable ([URL]) -> Bool)?
  var targeting: (@MainActor @Sendable (Bool) -> Void)?
}

private struct FileDropActionKey: EnvironmentKey {
  static let defaultValue = FileDropAction()
}

extension EnvironmentValues {
  var fileDropAction: FileDropAction {
    get { self[FileDropActionKey.self] }
    set { self[FileDropActionKey.self] = newValue }
  }
}

enum FileDropSupport {
  static func urls(from pasteboard: NSPasteboard) -> [URL] {
    (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL]) ?? []
  }

  /// Finder's file-url representation preserves the user-granted file access.
  /// Read providers in order so a multi-file drop keeps the Finder ordering.
  @MainActor
  static func urls(from providers: [NSItemProvider]) async throws -> [URL] {
    var urls: [URL] = []
    for provider in providers {
      let url: URL = try await withCheckedThrowingContinuation { continuation in
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
          item, error in
          if let error {
            continuation.resume(throwing: error)
            return
          }
          let url: URL?
          if let value = item as? URL {
            url = value
          } else if let data = item as? Data {
            url = URL(dataRepresentation: data, relativeTo: nil)
          } else if let value = item as? String {
            url = URL(string: value)
          } else {
            url = nil
          }
          guard let url, url.isFileURL else {
            continuation.resume(throwing: NativeDocumentError.invalidFile("拖入的内容不是本机文件。"))
            return
          }
          continuation.resume(returning: url)
        }
      }
      urls.append(url)
    }
    return urls
  }
}

/// Native PDFView handles its own drag destination before SwiftUI's ancestor can
/// receive the event. Forward file drags to the active workspace explicitly.
class FileReceivingPDFView: PDFView {
  var fileDropAction = FileDropAction()

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    registerForDraggedTypes([.fileURL])
  }

  override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
    guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else {
      return super.draggingEntered(sender)
    }
    guard fileDropAction.receive != nil else { return [] }
    fileDropAction.targeting?(true)
    return .copy
  }

  override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
    if sender.draggingPasteboard.availableType(from: [.fileURL]) != nil {
      return fileDropAction.receive == nil ? [] : .copy
    }
    return super.draggingUpdated(sender)
  }

  override func draggingExited(_ sender: (any NSDraggingInfo)?) {
    fileDropAction.targeting?(false)
    super.draggingExited(sender)
  }

  override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    if sender.draggingPasteboard.availableType(from: [.fileURL]) != nil {
      return fileDropAction.receive != nil
    }
    return super.prepareForDragOperation(sender)
  }

  override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
    guard sender.draggingPasteboard.availableType(from: [.fileURL]) != nil else {
      return super.performDragOperation(sender)
    }
    fileDropAction.targeting?(false)
    let urls = FileDropSupport.urls(from: sender.draggingPasteboard)
    guard !urls.isEmpty else { return false }
    return fileDropAction.receive?(urls) ?? false
  }
}
