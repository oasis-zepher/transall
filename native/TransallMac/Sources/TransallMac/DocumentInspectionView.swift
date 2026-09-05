import AppKit
import PDFKit
import SwiftUI

struct DocumentInspectionSnapshot: Sendable {
  let directory: URL
  let result: URL
  let original: URL?
}

struct DocumentInspectionRequest: Identifiable {
  let jobID: String
  let page: Int
  var id: String { jobID }
}

struct DocumentInspectionView: View {
  let backend: NativeDocumentEngine
  let request: DocumentInspectionRequest
  @Environment(\.dismiss) private var dismiss
  @State private var snapshot: DocumentInspectionSnapshot?
  @State private var error: String?
  @State private var compare = true
  @State private var scale: CGFloat = 1

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("检查文档").font(.headline)
        if snapshot?.original != nil {
          Toggle("原文对照", isOn: $compare).toggleStyle(.checkbox)
        }
        Spacer()
        Button("缩小", systemImage: "minus.magnifyingglass") {
          scale = max(0.25, scale / 1.25)
        }
        .labelStyle(.iconOnly).help("缩小文档")
        Button("放大", systemImage: "plus.magnifyingglass") {
          scale = min(4, scale * 1.25)
        }
        .labelStyle(.iconOnly).help("放大文档")
        Button("适合页面") { scale = 1 }
        Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      .padding(14)
      Divider()
      if let snapshot {
        HStack(spacing: 1) {
          if compare, let original = snapshot.original {
            pane("原文 · 提交时的副本", url: original)
          }
          pane("处理结果", url: snapshot.result)
        }
      } else if let error {
        ContentUnavailableView(
          "无法打开文档", systemImage: "exclamationmark.triangle", description: Text(error))
      } else {
        ProgressView("正在校验并准备文档")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(TransallTheme.paper)
    .foregroundStyle(TransallTheme.ink)
    .frame(
      minWidth: 700, idealWidth: 1120, maxWidth: .infinity,
      minHeight: 560, idealHeight: 760, maxHeight: .infinity
    )
    .task(id: request.jobID) {
      do {
        let files = try await backend.inspectionSnapshot(jobID: request.jobID)
        guard !Task.isCancelled else {
          try? FileManager.default.removeItem(at: files.directory)
          return
        }
        snapshot = files
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
    .onDisappear(perform: removeSnapshot)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) {
      _ in
      removeSnapshot()
    }
  }

  private func pane(_ title: String, url: URL) -> some View {
    VStack(spacing: 0) {
      Text(title).font(.caption.weight(.semibold))
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
      InspectionPDFView(url: url, scale: scale, initialPage: request.page)
        .accessibilityLabel(title)
    }
    .background(TransallTheme.panel)
  }

  private func removeSnapshot() {
    if let snapshot { try? FileManager.default.removeItem(at: snapshot.directory) }
    snapshot = nil
  }
}

private struct InspectionPDFView: NSViewRepresentable {
  let url: URL
  let scale: CGFloat
  let initialPage: Int

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1)
    view.document = PDFDocument(url: url)
    view.autoScales = true
    if let document = view.document,
      let page = document.page(at: min(document.pageCount - 1, max(0, initialPage - 1)))
    {
      view.go(to: page)
    }
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) {
    view.autoScales = scale == 1
    if scale != 1 { view.scaleFactor = view.scaleFactorForSizeToFit * scale }
  }
}
