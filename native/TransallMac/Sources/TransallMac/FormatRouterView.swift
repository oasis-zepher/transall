import SwiftUI

struct FormatRouterView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack {
        SectionLabel(text: "Format route")
        Spacer()
        Text(selectionHint)
          .font(.caption2)
          .foregroundStyle(TransallTheme.muted)
      }

      orbit
        .frame(height: 348)

      routeDetails
    }
  }

  private var orbit: some View {
    GeometryReader { proxy in
      let size = min(proxy.size.width, proxy.size.height)
      let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
      let radius = size * 0.405

      ZStack {
        Circle()
          .stroke(TransallTheme.line.opacity(0.75), lineWidth: 1)
          .frame(width: radius * 2, height: radius * 2)
        Circle()
          .stroke(TransallTheme.line.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
          .frame(width: radius * 1.28, height: radius * 1.28)
        Rectangle()
          .fill(TransallTheme.line.opacity(0.35))
          .frame(width: radius * 2.1, height: 1)
        Rectangle()
          .fill(TransallTheme.line.opacity(0.35))
          .frame(width: 1, height: radius * 2.1)

        ForEach(Array(model.formatOrder.enumerated()), id: \.element) { index, format in
          let angle =
            (Double(index) / Double(model.formatOrder.count)) * 2 * Double.pi - Double.pi / 2
          FormatNode(
            format: format,
            label: model.capabilities?.formats[format]?.label ?? fallbackLabel(for: format),
            state: state(for: format),
            action: { model.chooseFormat(format, animated: !reduceMotion) }
          )
          .position(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
          )
        }

        routeCore
          .position(center)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var routeCore: some View {
    VStack(spacing: 7) {
      routeSlot(title: "源格式", format: model.selection.source, color: TransallTheme.source)

      Image(systemName: "arrow.down")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(TransallTheme.muted)

      routeSlot(title: "目标格式", format: model.selection.target, color: TransallTheme.target)
    }
    .padding(12)
    .frame(width: 122)
    .background(TransallTheme.panel.opacity(0.97))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(TransallTheme.lineStrong, lineWidth: 1)
    }
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .shadow(color: TransallTheme.ink.opacity(0.09), radius: 12, y: 5)
  }

  private func routeSlot(title: String, format: String?, color: Color) -> some View {
    VStack(spacing: 2) {
      Text(title)
        .font(.caption2.weight(.medium))
        .foregroundStyle(TransallTheme.muted)
      Text(format.map { model.capabilities?.formats[$0]?.label ?? fallbackLabel(for: $0) } ?? "待选择")
        .font(.callout.weight(.bold))
        .minimumScaleFactor(0.75)
        .foregroundStyle(format == nil ? TransallTheme.lineStrong : color)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 6)
    .background(color.opacity(format == nil ? 0.03 : 0.08))
    .clipShape(RoundedRectangle(cornerRadius: 4))
  }

  private var routeDetails: some View {
    WorkbenchPanel {
      VStack(alignment: .leading, spacing: 13) {
        HStack(alignment: .firstTextBaseline) {
          Text(model.route?.title ?? "路径详情")
            .font(.system(.headline, design: .serif, weight: .semibold))
          Spacer()
          Text(routeState)
            .font(.caption2.weight(.bold))
            .foregroundStyle(routeStateColor)
        }

        Text(routeSummary)
          .font(.caption)
          .foregroundStyle(TransallTheme.inkSoft)
          .fixedSize(horizontal: false, vertical: true)

        if let route = model.route {
          Divider().overlay(TransallTheme.line)
          fact(label: "任务", value: route.kindLabel)
          fact(label: "输入", value: route.input)
          fact(label: "输出", value: route.output)
          fact(label: "引擎", value: engineLine(route))

          if !route.requirements.isEmpty {
            Divider().overlay(TransallTheme.line)
            SectionLabel(text: "Dependencies")
            ForEach(route.requirements) { requirement in
              dependencyRow(requirement)
            }
          }
        }
      }
    }
  }

  private func fact(label: String, value: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Text(label)
        .font(.caption2.weight(.medium))
        .foregroundStyle(TransallTheme.muted)
        .frame(width: 34, alignment: .leading)
      Text(value)
        .font(.caption2)
        .foregroundStyle(TransallTheme.inkSoft)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func dependencyRow(_ requirement: RouteRequirement) -> some View {
    let diagnostic = model.diagnostic(for: requirement)
    let available = diagnostic?.available == true
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
        .foregroundStyle(available ? TransallTheme.source : TransallTheme.warning)
        .font(.caption)
      VStack(alignment: .leading, spacing: 2) {
        Text(diagnostic?.label ?? requirement.name)
          .font(.caption2.weight(.semibold))
        if !available, let hint = diagnostic?.installHint, !hint.isEmpty {
          Text(hint)
            .font(.caption2)
            .foregroundStyle(TransallTheme.muted)
            .textSelection(.enabled)
        }
      }
    }
  }

  private func engineLine(_ route: RouteDefinition) -> String {
    ([route.engine] + route.fallbackEngines).filter { !$0.isEmpty }.joined(separator: " / ")
  }

  private var selectionHint: String {
    if model.selection.source == nil { return "① 源格式" }
    if model.selection.target == nil { return "② 目标格式" }
    return "路径已选"
  }

  private var routeSummary: String {
    if let route = model.route { return route.summary }
    if model.selection.source == nil { return "点击圆盘中的两个格式。第一个是源格式，第二个是目标格式。" }
    return "继续选择输出格式；再次点击同一格式可选择 PDF → PDF 等路径。"
  }

  private var routeState: String {
    guard model.selection.target != nil else { return "等待选择" }
    return model.route?.enabled == true ? "可用" : "未接入"
  }

  private var routeStateColor: Color {
    guard model.selection.target != nil else { return TransallTheme.muted }
    return model.route?.enabled == true ? TransallTheme.source : TransallTheme.danger
  }

  private func state(for format: String) -> FormatNode.State {
    if model.selection.target == format { return .target }
    if model.selection.source == format { return .source }
    guard let source = model.selection.source else {
      let isSource =
        model.capabilities?.routes.contains { $0.source == format && $0.enabled } == true
      return isSource ? .available : .unavailable
    }
    guard model.selection.target == nil else {
      return .available
    }
    let isAvailable =
      model.capabilities?.routes.contains {
        $0.source == source && $0.target == format && $0.enabled
      } == true
    return isAvailable ? .available : .unavailable
  }

  private func fallbackLabel(for format: String) -> String {
    switch format {
    case "translated_pdf": "中文PDF"
    case "image": "Image"
    case "data": "Data"
    default: format.uppercased()
    }
  }
}

private struct FormatNode: View {
  enum State: Equatable { case available, unavailable, source, target }

  let format: String
  let label: String
  let state: State
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: label.count > 5 ? 9 : 10, weight: .bold, design: .rounded))
        .minimumScaleFactor(0.72)
        .lineLimit(1)
        .foregroundStyle(foreground)
        .frame(width: 58, height: 58)
        .background(background)
        .overlay {
          Circle().stroke(border, lineWidth: state == .source || state == .target ? 2 : 1)
        }
        .clipShape(Circle())
        .shadow(color: TransallTheme.ink.opacity(state == .unavailable ? 0 : 0.1), radius: 7, y: 3)
    }
    .buttonStyle(.plain)
    .disabled(state == .unavailable)
    .opacity(state == .unavailable ? 0.34 : 1)
    .accessibilityLabel("\(label)格式")
    .accessibilityValue(accessibilityValue)
  }

  private var foreground: Color {
    switch state {
    case .source, .target: .white
    case .available: TransallTheme.formatColors[format] ?? TransallTheme.ink
    case .unavailable: TransallTheme.muted
    }
  }

  private var background: Color {
    switch state {
    case .source: TransallTheme.source
    case .target: TransallTheme.target
    case .available: TransallTheme.panel
    case .unavailable: TransallTheme.panelMuted
    }
  }

  private var border: Color {
    switch state {
    case .source: TransallTheme.source
    case .target: TransallTheme.target
    case .available: TransallTheme.formatColors[format] ?? TransallTheme.lineStrong
    case .unavailable: TransallTheme.line
    }
  }

  private var accessibilityValue: String {
    switch state {
    case .source: "已选为源格式"
    case .target: "已选为目标格式"
    case .available: "可选择"
    case .unavailable: "当前源格式不支持此目标"
    }
  }
}
