import SwiftUI

struct InputFileListView: View {
  @EnvironmentObject private var model: AppModel
  @State private var hoveredFileID: URL?

  private var canRemove: Bool { !model.isImporting && model.canEditTaskDraft }

  private func showsRemoval(for document: SelectedDocument) -> Bool {
    hoveredFileID == document.id
      || (model.showInputPreview && model.selectedDocumentID == document.id)
  }

  var body: some View {
    List(
      selection: Binding<URL?>(
        get: { model.showInputPreview ? model.selectedDocumentID : nil },
        set: { model.selectedDocumentID = $0 }
      )
    ) {
      Section {
        ForEach(model.documents) { document in
          HStack(spacing: 8) {
            Image(
              systemName: document.url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc"
            )
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(document.name).lineLimit(1).truncationMode(.middle)
              Text(document.formattedSize).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("移除文件", systemImage: "xmark") { model.removeDocument(document) }
              .labelStyle(.iconOnly).buttonStyle(.borderless)
              .disabled(!canRemove || !showsRemoval(for: document))
              .opacity(showsRemoval(for: document) ? 1 : 0)
              .accessibilityHidden(!showsRemoval(for: document))
              .accessibilityLabel("移除\(document.name)")
          }
          .help(document.name).tag(document.id)
          .onHover { hovering in
            if hovering {
              hoveredFileID = document.id
            } else if hoveredFileID == document.id {
              hoveredFileID = nil
            }
          }
          .accessibilityAction(named: "移除文件") {
            if canRemove { model.removeDocument(document) }
          }
          .contextMenu {
            Button("移除文件", role: .destructive) { model.removeDocument(document) }
              .disabled(!canRemove)
          }
        }
        if model.documents.isEmpty {
          Text("尚未添加文件").font(.callout).foregroundStyle(.secondary)
        }
      } header: {
        HStack {
          Text("文件 · \(model.documents.count)")
          Spacer()

        }
      }
    }
    .listStyle(.sidebar)
    .accessibilityLabel("当前任务的文件")
    .onDeleteCommand {
      guard canRemove, model.showInputPreview,
        let document = model.documents.first(where: { $0.id == model.selectedDocumentID })
      else { return }
      model.removeDocument(document)
    }
  }
}
