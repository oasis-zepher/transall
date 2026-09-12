import AppKit
import ImageIO
import SwiftUI

struct WorkspacePreviewView: View {
  @EnvironmentObject private var model: AppModel
  @State private var targeted = false

  var body: some View {
    Group {
      if let job = model.currentJob,
        (job.status == "done" && !model.showInputPreview) || model.translationRecovery != nil
      {
        DocumentInspectionView(
          backend: model.backend,
          request: DocumentInspectionRequest(jobID: job.id, page: model.inspectionPage),
          embedded: true
        )
        .id("\(job.id)-\(job.status)-\(model.inspectionPage)")
      } else if let document = model.documents.first(where: { $0.id == model.selectedDocumentID }) {
        VStack(spacing: 0) {
          if model.currentJob?.status == "done" {
            HStack {
              Text("输入文件").font(.caption).foregroundStyle(.secondary)
              Spacer()
              Button("查看处理结果") { model.showInputPreview = false }.buttonStyle(.borderless)
            }.padding(12).background(TransallTheme.paper)
          }
          SourceDocumentPreview(document: document).id(document.id)
        }
      } else {
        emptyState
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
    .overlay {
      if targeted {
        Rectangle().strokeBorder(TransallTheme.accent, lineWidth: 3).allowsHitTesting(false)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard model.canSelectDocuments, !urls.isEmpty else { return false }
      model.startDocumentImport(urls, appending: !model.documents.isEmpty)
      return true
    } isTargeted: {
      targeted = $0 && model.canSelectDocuments
    }
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: model.selectedTask.symbol)
        .font(.system(size: 40, weight: .light)).foregroundStyle(.tertiary)
        .accessibilityHidden(true)
      Text(model.selectedTask.title).font(.title2.weight(.semibold))
      Text(model.isImporting ? "正在读取文件…" : "将文件拖到这里")
        .foregroundStyle(.secondary)
      Button("选择文件…") {
        NotificationCenter.default.post(name: .transallChooseDocuments, object: nil)
      }
      .buttonStyle(PrimaryButtonStyle()).disabled(!model.canSelectDocuments)
      if let route = model.route {
        Text(route.accept).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(28)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文件选择区")

  }
}

struct InputPreviewSnapshot: Sendable {
  let directory: URL
  let url: URL

  static func create(for document: SelectedDocument) async throws -> Self {
    let operation = Task.detached(priority: .userInitiated) {
      let accessing = document.url.startAccessingSecurityScopedResource()
      defer { if accessing { document.url.stopAccessingSecurityScopedResource() } }
      let (input, initial) = try SecureFileTransfer.openRegularSource(
        document.url, nonRegularMessage: "文件无法预览，请重新选择原始文件。")
      defer { try? input.close() }
      guard initial.st_size <= NativeCapabilities.uploadLimitBytes, initial.st_size == document.size
      else {
        throw NativeDocumentError.invalidFile("文件大小已改变或超过预览上限，请重新选择文件。")
      }
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "TransallPreview-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      var success = false
      defer { if !success { try? FileManager.default.removeItem(at: directory) } }
      let url = directory.appendingPathComponent(document.name)
      let output = try SecureFileTransfer.openNewDestination(url)
      defer { try? output.close() }
      var count: Int64 = 0
      while let chunk = try input.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
        try Task.checkCancellation()
        count += Int64(chunk.count)
        guard count <= initial.st_size else {
          throw NativeDocumentError.invalidFile("文件在预览期间发生变化，请重新选择文件。")
        }
        try output.write(contentsOf: chunk)
      }
      let final = try SecureFileTransfer.fileStatus(for: input.fileDescriptor)
      guard count == initial.st_size, SecureFileTransfer.isUnchanged(initial, final) else {
        throw NativeDocumentError.invalidFile("文件在预览期间发生变化，请重新选择文件。")
      }
      try Task.checkCancellation()
      success = true
      return Self(directory: directory, url: url)
    }
    return try await withTaskCancellationHandler(
      operation: { try await operation.value }, onCancel: { operation.cancel() })
  }
}

private struct SourceDocumentPreview: View {
  let document: SelectedDocument
  @State private var snapshot: InputPreviewSnapshot?
  @State private var error: String?
  @State private var scale: CGFloat = 1
  @StateObject private var controller = InspectionPDFController()

  private var previewable: Bool {
    ["pdf", "png", "jpg", "jpeg", "tiff", "heic"].contains(document.url.pathExtension.lowercased())
  }

  var body: some View {
    Group {
      if !previewable {
        ContentUnavailableView(
          document.name, systemImage: "doc.text",
          description: Text("\(document.formattedSize)\n处理完成后可在这里查看结果。"))
      } else if let snapshot {
        if document.url.pathExtension.lowercased() == "pdf" {
          InspectionPane(
            title: document.name, url: snapshot.url, scale: $scale,
            initialPage: 1, controller: controller)
        } else {
          ImageDocumentPreview(url: snapshot.url, name: document.name)
        }
      } else if let error {
        ContentUnavailableView(
          "无法预览", systemImage: "doc.badge.exclamationmark", description: Text(error))
      } else {
        ProgressView("正在打开文件")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: document.id) {
      guard previewable else { return }
      do {
        let result = try await InputPreviewSnapshot.create(for: document)
        guard !Task.isCancelled else {
          try? FileManager.default.removeItem(at: result.directory)
          return
        }
        snapshot = result
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
    .onDisappear(perform: cleanUp)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) {
      _ in cleanUp()
    }
  }

  private func cleanUp() {
    controller.detach()
    if let snapshot { try? FileManager.default.removeItem(at: snapshot.directory) }
    snapshot = nil
  }
}

private struct ImageDocumentPreview: View {
  let url: URL
  let name: String
  @State private var image: NSImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFit().padding(24).accessibilityLabel(name)
      } else if failed {
        ContentUnavailableView("无法读取图片", systemImage: "photo.badge.exclamationmark")
      } else {
        ProgressView("正在打开图片")
      }
    }
    .task(id: url) {
      let thumbnail = await Task.detached(priority: .userInitiated) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
          return nil as CGImage?
        }
        return CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2400,
          ] as CFDictionary)
      }.value
      guard !Task.isCancelled else { return }
      image = thumbnail.map { NSImage(cgImage: $0, size: .zero) }
      failed = image == nil
    }
  }
}

struct TextResultPreview: View {
  let url: URL
  @State private var text: String?
  @State private var limited = false
  @State private var error: String?
  nonisolated static let byteLimit = 200_000

  var body: some View {
    Group {
      if let text {
        VStack(spacing: 0) {
          if limited {
            Text("仅预览前 200 KB，保存结果可查看全文。")
              .font(.caption).foregroundStyle(.secondary).padding(12)
          }
          ScrollView {
            Text(text).textSelection(.enabled).font(.body)
              .frame(maxWidth: .infinity, alignment: .topLeading).padding(24)
          }
        }
      } else if let error {
        ContentUnavailableView(
          "无法读取结果", systemImage: "doc.badge.exclamationmark", description: Text(error))
      } else {
        ProgressView("正在读取结果")
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TransallTheme.panel)
    .task(id: url) {
      do {
        let data = try await Task.detached(priority: .userInitiated) {
          let (handle, _) = try SecureFileTransfer.openRegularSource(
            url, nonRegularMessage: "结果文件不可读取。")
          defer { try? handle.close() }
          return try handle.read(upToCount: Self.byteLimit + 1) ?? Data()
        }.value
        guard !Task.isCancelled else { return }
        limited = data.count > Self.byteLimit
        text = String(decoding: data.prefix(Self.byteLimit), as: UTF8.self)
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
  }
}
