import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @State private var fileDropTargeted = false
  @State private var page = "convert"
  @StateObject private var editor = PDFEditorModel()
  @State private var showRouter = true
  @State private var orbitOrder = NativeFormatOrbit.formats
  @State private var parametersRevealed = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("工作区", selection: $page) {
          Text("格式转换").tag("convert")
          Text("PDF 编辑").tag("editor")
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
        .accessibilityIdentifier("workspace.navigation")
        Spacer()
      }
      .padding(.horizontal, 20).padding(.vertical, 10)
      Divider()
      if page == "editor" {
        PDFEditorView(model: editor)
      } else {
        ConversionWorkbenchView(
          showRouter: $showRouter, orbitOrder: $orbitOrder,
          parametersRevealed: $parametersRevealed)
      }
    }
    .contentShape(Rectangle())
    .environment(
      \.fileDropAction,
      FileDropAction(receive: { receiveFiles($0) }, targeting: { fileDropTargeted = $0 })
    )
    .onDrop(of: [UTType.fileURL.identifier], isTargeted: $fileDropTargeted) { providers in
      guard !providers.isEmpty else { return false }
      Task { @MainActor in
        do { _ = receiveFiles(try await FileDropSupport.urls(from: providers)) } catch {
          if page == "editor" {
            editor.error = error.localizedDescription
          } else {
            model.errorMessage = error.localizedDescription
          }
        }
      }
      return true
    }
    .overlay {
      if fileDropTargeted {
        ZStack {
          Rectangle().fill(TransallTheme.accent.opacity(0.08))
          Rectangle().strokeBorder(TransallTheme.accent, lineWidth: 3)
          Label(page == "editor" ? "松开以打开 PDF" : "松开以添加文件", systemImage: "arrow.down.doc")
            .font(.headline).padding(20).background(
              .regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .allowsHitTesting(false)
      }
    }
  }

  private func receiveFiles(_ urls: [URL]) -> Bool {
    fileDropTargeted = false
    if page == "editor" { return editor.receiveDroppedFiles(urls) }
    return model.receiveDroppedDocuments(urls)
  }
}

private struct ConversionWorkbenchView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Binding var showRouter: Bool
  @Binding var orbitOrder: [String]
  @Binding var parametersRevealed: Bool
  @State private var showImporter = false

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        if showRouter {
          HStack(spacing: 0) {
            FormatRouterView(ringOrder: $orbitOrder)
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            parameterPanel
              .frame(width: parametersRevealed ? (geometry.size.width < 1040 ? 270 : 300) : 0)
              .clipped()
              .accessibilityHidden(!parametersRevealed)
          }
        } else {
          HStack(spacing: 0) {
            documentSidebar
              .frame(width: geometry.size.width < 1040 ? 220 : 260)
            Divider()
            WorkspacePreviewView()
          }
        }
        Divider()
        HStack(alignment: .bottom, spacing: 0) {
          ResultWorkbenchView().frame(maxWidth: .infinity)
          SettingsLink { Label("设置", systemImage: "gearshape") }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .help("设置（⌘,）").accessibilityLabel("设置")
            .padding(14)
        }
        .background(TransallTheme.paper)
      }
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: parametersRevealed)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: showRouter)
    }
    .toolbar {
      // A principal item keeps the native trailing items at the right edge without a visible title.
      if #available(macOS 26.0, *) {
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
          .sharedBackgroundVisibility(.hidden)
      } else {
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("添加文件", systemImage: "plus") { chooseDocuments() }
          .disabled(!model.canSelectDocuments).help("添加文件（⌘O）")
          .accessibilityIdentifier("task.addFiles")
      }
      ToolbarItem(placement: .confirmationAction) { TaskExecutionButton() }
      ToolbarItem(placement: .confirmationAction) {
        Button("下载", systemImage: "arrow.down.to.line") { model.startSavingResult() }
          .disabled(!model.canStartSavingResult)
          .keyboardShortcut("s", modifiers: .command)
          .help("下载并保存结果（⌘S）").accessibilityLabel("下载结果")
          .accessibilityIdentifier("task.download")
      }
    }
    .onAppear {
      if model.route != nil { parametersRevealed = true }
    }
    .onChange(of: model.route?.id) { _, routeID in
      if routeID != nil { parametersRevealed = true }
    }
    .onChange(of: model.documents.isEmpty) { _, empty in
      if !empty { showRouter = false }
    }
    .onChange(of: model.currentJob?.id) { _, jobID in
      if jobID != nil { showRouter = false }
    }
    .onChange(of: model.selection) { _, _ in
      if model.documents.isEmpty && model.currentJob == nil { showRouter = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: .transallChooseDocuments)) { _ in
      chooseDocuments()
    }
    .alert(
      "任务未能继续",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("关闭", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "未知错误")
    }
  }

  private func chooseDocuments() {
    guard model.canSelectDocuments, !showImporter else { return }
    showImporter = true
    // Configure at presentation time, after restored task options have arrived.
    let panel = NSOpenPanel()
    panel.allowedContentTypes = WorkbenchTask.contentTypes(source: model.selection.source)
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.begin { response in
      showImporter = false
      guard response == .OK else { return }
      model.startDocumentImport(panel.urls, appending: !model.documents.isEmpty)
    }
  }

  private var parameterPanel: some View {
    VStack(spacing: 0) {
      if !model.documents.isEmpty || model.currentJob != nil {
        Button("查看文档", systemImage: "doc.richtext") { showRouter = false }
          .buttonStyle(.borderless).padding(16)
        Divider()
      }
      if model.route != nil {
        InputWorkbenchView()
      } else {
        ContentUnavailableView(
          "转换参数", systemImage: "slider.horizontal.3",
          description: Text("选好源格式与目标格式后，在这里调整参数。"))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TransallTheme.panel)
    .overlay(alignment: .leading) { Divider() }
  }

  private var documentSidebar: some View {
    VStack(spacing: 0) {
      Button {
        showRouter = true
      } label: {
        VStack(spacing: 0) {
          compactRole(model.selection.source, title: "源格式")
          Spacer(minLength: 16)
          compactRole(model.selection.target, title: "目标格式")
        }
        .padding(.vertical, 10)
        .frame(width: 150, height: 126)
        .modifier(HourglassSurface(rotation: 0))
      }
      .buttonStyle(.plain)
      .help("展开格式转盘，保留当前文件与参数")
      .accessibilityLabel("展开格式转盘")
      .accessibilityIdentifier("workspace.hourglass")
      .padding(.top, 20).padding(.bottom, 8)
      Text("点击沙漏更改格式").font(.caption).foregroundStyle(.secondary).padding(.bottom, 16)
      Divider()
      InputFileListView().frame(height: 132)
      Divider()
      InputWorkbenchView()
    }
    .background(TransallTheme.panel)
  }

  private func compactRole(_ format: String?, title: String) -> some View {
    VStack(spacing: 2) {
      Text(title).font(.caption2).foregroundStyle(.secondary)
      Text(format.map(NativeFormatOrbit.title) ?? "未选择")
        .font(.callout.weight(.semibold)).lineLimit(1)
    }
  }
}
