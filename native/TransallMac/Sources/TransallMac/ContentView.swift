import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      PaperGridBackground()

      VStack(spacing: 0) {
        GeometryReader { proxy in
          ScrollView {
            if proxy.size.width >= 1040 {
              HStack(alignment: .top, spacing: 22) {
                FormatRouterView()
                  .frame(width: 348)
                workbench
              }
              .padding(22)
            } else {
              VStack(spacing: 18) {
                FormatRouterView()
                  .frame(maxWidth: 620)
                workbench
              }
              .padding(18)
            }
          }
          .scrollIndicators(.hidden)
        }
      }
    }
    .foregroundStyle(TransallTheme.ink)
    .tint(TransallTheme.accent)
    .toolbar {
      ToolbarItem(placement: .principal) {
        HStack(spacing: 14) {
          Text("transall")
            .font(.system(.title3, design: .serif, weight: .semibold))
          VStack(alignment: .leading, spacing: 1) {
            Text(model.routeTitle).font(.callout.weight(.semibold)).lineLimit(1)
            Text(routeStep).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }
      ToolbarItem(placement: .status) {
        Label(model.backend.state.label, systemImage: serviceSymbol)
          .font(.caption)
          .foregroundStyle(serviceColor)
          .help(model.backend.state.label)
      }
      ToolbarItemGroup(placement: .primaryAction) {
        if case .failed = model.backend.state {
          Button("重试", systemImage: "arrow.clockwise") {
            Task { await model.retryBackend() }
          }
        }
        Button("选择文件…", systemImage: "plus") {
          NotificationCenter.default.post(name: .transallChooseDocuments, object: nil)
        }
        .disabled(!model.canSelectDocuments)
        .help("选择要处理的文件（⌘O）")
        if model.selection.source != nil {
          Button("重选路径", systemImage: "arrow.uturn.backward") {
            model.resetRoute(animated: !reduceMotion)
          }
          .disabled(!model.canChangeRoute)
          .help(resetRouteHelp)
        }
        SettingsLink { Label("设置", systemImage: "gearshape") }
          .help("翻译服务与隐私设置")
      }
    }
    .alert(
      "任务未能继续",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.errorMessage = nil } }
      )
    ) {
      Button("关闭", role: .cancel) { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "未知错误")
    }
  }

  private var workbench: some View {
    VStack(spacing: 16) {
      InputWorkbenchView()
      ResultWorkbenchView()
    }
    .frame(maxWidth: .infinity)
  }

  private var routeStep: String {
    if model.selection.source == nil { return "先选源格式，再选目标格式" }
    if model.selection.target == nil { return "源格式已确定，选择目标格式" }
    if model.route?.enabled == false { return "此路径尚未接入" }
    return model.route?.kindLabel ?? "准备任务"
  }

  private var serviceSymbol: String {
    switch model.backend.state {
    case .starting: "hourglass"
    case .running: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var serviceColor: Color {
    switch model.backend.state {
    case .starting: TransallTheme.warning
    case .running: TransallTheme.source
    case .failed: TransallTheme.danger
    }
  }

  private var resetRouteHelp: String {
    if let routeChangeLock = model.routeChangeLock { return routeChangeLock.helpText }
    return "重新选择源格式和目标格式"
  }
}
