import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    ZStack {
      PaperGridBackground()

      VStack(spacing: 0) {
        header
        Divider().overlay(TransallTheme.line)

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

  private var header: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 1) {
        Text("LOCAL DOCUMENT ROUTER")
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .tracking(1.7)
          .foregroundStyle(TransallTheme.muted)
        Text("transall")
          .font(.system(size: 25, weight: .semibold, design: .serif))
      }

      Rectangle()
        .fill(TransallTheme.line)
        .frame(width: 1, height: 34)

      VStack(alignment: .leading, spacing: 2) {
        Text(model.routeTitle)
          .font(.system(size: 13, weight: .semibold))
          .lineLimit(1)
        Text(routeStep)
          .font(.system(size: 11))
          .foregroundStyle(TransallTheme.muted)
      }

      Spacer(minLength: 10)

      HStack(spacing: 8) {
        Circle()
          .fill(serviceColor)
          .frame(width: 7, height: 7)
        Text(model.backend.state.label)
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(TransallTheme.inkSoft)

        if case .failed = model.backend.state {
          Button("重试") {
            Task { await model.retryBackend() }
          }
          .buttonStyle(QuietButtonStyle())
        }

        if model.selection.source != nil {
          Button("重选路径") { model.resetRoute() }
            .buttonStyle(QuietButtonStyle())
            .disabled(model.currentJob?.isRunning == true)
            .help(model.currentJob?.isRunning == true ? "先取消正在运行的任务" : "重新选择源格式和目标格式")
        }
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, 13)
    .background(TransallTheme.panel.opacity(0.96))
  }

  private var routeStep: String {
    if model.selection.source == nil { return "先选源格式，再选目标格式" }
    if model.selection.target == nil { return "源格式已确定，选择目标格式" }
    if model.route?.enabled == false { return "此路径尚未接入" }
    return model.route?.kindLabel ?? "准备任务"
  }

  private var serviceColor: Color {
    switch model.backend.state {
    case .starting: TransallTheme.warning
    case .running: TransallTheme.source
    case .failed: TransallTheme.danger
    }
  }
}

struct QuietButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 11, weight: .semibold))
      .foregroundStyle(TransallTheme.inkSoft)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(configuration.isPressed ? TransallTheme.panelMuted : .clear)
      .overlay {
        RoundedRectangle(cornerRadius: 5)
          .stroke(TransallTheme.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 5))
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.72))
      .padding(.horizontal, 16)
      .padding(.vertical, 9)
      .background(
        isEnabled
          ? TransallTheme.accent.opacity(configuration.isPressed ? 0.82 : 1)
          : TransallTheme.lineStrong
      )
      .clipShape(RoundedRectangle(cornerRadius: 5))
  }
}
