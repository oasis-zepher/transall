import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showRouter = true
  @State private var orbitOrder = NativeFormatOrbit.formats
  @State private var visibility: NavigationSplitViewVisibility = .all
  @State private var showInspector = true
  @State private var showImporter = false
  @State private var showFiles = false

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        if showRouter {
          FormatRouterView(ringOrder: $orbitOrder)
            .transition(workspaceTransition)
        } else if geometry.size.width >= 1040 {
          NavigationSplitView(columnVisibility: $visibility) {
            InputFileListView().navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
          } detail: {
            workspace(compact: false)
          }
          .navigationSplitViewStyle(.balanced)
          .transition(workspaceTransition)
        } else {
          workspace(compact: true)
            .transition(workspaceTransition)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: showRouter)
      .inspector(
        isPresented: Binding(
          get: { showInspector && model.route != nil },
          set: { showInspector = $0 }
        )
      ) {
        InputWorkbenchView().inspectorColumnWidth(min: 260, ideal: 280, max: 340)
      }
    }
    .toolbar {
      ToolbarItem(placement: .navigation) {
        if showRouter {
          if !model.documents.isEmpty || model.currentJob != nil {
            Button("查看文档", systemImage: "doc.richtext") { showRouter = false }
          }
        } else {
          Button("格式转盘", systemImage: "circle.dotted") { showRouter = true }
        }
      }
      ToolbarItem(placement: .principal) {
        Text(showRouter ? "Transall" : model.selectedTask.title).font(.headline).fixedSize()
      }
      ToolbarItemGroup(placement: .primaryAction) {
        Button("选择文件…", systemImage: "plus") {
          showImporter = true
        }
        .disabled(!model.canSelectDocuments).help("选择文件（⌘O）")
        if !showInspector && model.route != nil { TaskActionButtons() }
        Button("任务参数", systemImage: "sidebar.right") { showInspector.toggle() }
          .help(showInspector ? "隐藏任务参数" : "显示任务参数").disabled(model.route == nil)
        SettingsLink { Label("设置", systemImage: "gearshape") }
      }
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
    .onChange(of: model.route?.id) { _, routeID in
      if routeID != nil { showInspector = true }
    }
    .fileImporter(
      isPresented: $showImporter,
      allowedContentTypes: WorkbenchTask.contentTypes(source: model.selection.source),
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): model.startDocumentImport(urls, appending: !model.documents.isEmpty)
      case .failure(let error): model.errorMessage = error.localizedDescription
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .transallChooseDocuments)) { _ in
      guard model.canSelectDocuments else { return }
      showImporter = true
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

  private var workspaceTransition: AnyTransition {
    reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.985))
  }

  private func workspace(compact: Bool) -> some View {
    VStack(spacing: 0) {
      if compact {
        DisclosureGroup("文件 · \(model.documents.count)", isExpanded: $showFiles) {
          InputFileListView().frame(height: 140)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        Divider()
      }
      WorkspacePreviewView()
      Divider()
      ResultWorkbenchView()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(TransallTheme.paper)
  }
}
