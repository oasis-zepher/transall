import SwiftUI

struct OrbitFormatButton: View {
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let format: String
  let diameter: CGFloat
  let selected: Bool
  let roles: OrbitFormatRoles
  let enabled: Bool
  var chamberAppearance = 0.0
  var labelOpacity = 1.0
  var concealed = false
  var previewRoles: OrbitFormatRoles? = nil
  var previewAmount = 0.0
  var supportOverride: [Double]? = nil
  var moduleSize: CGSize? = nil
  var labelWidth: CGFloat? = nil
  var morphSlot: FormatRouteSlot = .source
  var morphAmount = 0.0
  let action: () -> Void

  var body: some View {
    let width = moduleSize?.width ?? diameter
    let height = moduleSize?.height ?? diameter
    let shape = OrbitModuleShape(slot: morphSlot, amount: morphAmount)
    let displayedRoles = previewAmount > 0 ? (previewRoles ?? roles) : roles
    let sourceSupport =
      supportOverride?.first ?? support(roles.source, preview: previewRoles?.source)
    let targetSupport =
      supportOverride?.last ?? support(roles.target, preview: previewRoles?.target)
    Button(action: action) {
      ZStack {
        Color.clear.frame(width: width, height: height)
        if !concealed {
          VStack(spacing: 7) {
            Image(systemName: NativeFormatOrbit.symbol(format)).font(.system(size: diameter * 0.24))
            Text(NativeFormatOrbit.title(format))
              .font(.system(size: diameter < 75 ? 11 : 13, weight: .medium))
              .lineLimit(1).minimumScaleFactor(0.8)
          }
          .frame(width: labelWidth)
          .foregroundStyle(TransallTheme.ink)
          .opacity(labelOpacity)
          .offset(y: height * morphAmount * (morphSlot == .source ? -0.15 : 0.15))
          .frame(width: width, height: height)
          .overlay(alignment: .topTrailing) {
            if differentiateWithoutColor && !displayedRoles.source {
              Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).padding(7)
            }
          }
          .overlay(alignment: .bottomTrailing) {
            if differentiateWithoutColor && !displayedRoles.target {
              Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).padding(7)
            }
          }
          .modifier(
            OrbitModuleSurface(
              selected: selected, sourceSupport: sourceSupport, targetSupport: targetSupport,
              shape: shape, chamberAppearance: chamberAppearance
            )
          )
          .animation(
            reduceMotion
              ? nil
              : .easeInOut(
                duration: previewAmount > 0
                  ? OrbitDragGeometry.approachDuration : OrbitDragGeometry.retractDuration),
            value: [sourceSupport, targetSupport])
        }
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(NativeFormatOrbit.title(format))
    .accessibilityValue(displayedRoles.description)
    .accessibilityHint("上半部代表源格式，下半部代表输出格式；拖入对应腔室，或点击选择")
    .help(displayedRoles.description)
  }

  private func support(_ current: Bool, preview: Bool?) -> Double {
    let start = current ? 1.0 : 0.0
    let end = (preview ?? current) ? 1.0 : 0.0
    return start + (end - start) * max(0, min(1, previewAmount))
  }
}

private struct OrbitModuleSurface: ViewModifier, Animatable {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let selected: Bool
  nonisolated var sourceSupport: Double
  nonisolated var targetSupport: Double
  let shape: OrbitModuleShape
  let chamberAppearance: Double

  nonisolated var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(sourceSupport, targetSupport) }
    set {
      sourceSupport = newValue.first
      targetSupport = newValue.second
    }
  }

  private func roleGradient() -> LinearGradient {
    // Supported halves reveal the same native surface as the empty chamber.
    let unavailable = TransallTheme.orbitUnavailable(for: colorScheme)
    let source = unavailable.opacity(1 - sourceSupport)
    let target = unavailable.opacity(1 - targetSupport)
    return LinearGradient(
      stops: [
        .init(color: source, location: 0), .init(color: source, location: 0.28),
        .init(color: target, location: 0.72), .init(color: target, location: 1),
      ], startPoint: .top, endPoint: .bottom)
  }

  private func fill(glass: Bool) -> some View {
    ZStack {
      if !glass { TransallTheme.orbitVacancy }
      roleGradient().opacity(1 - chamberAppearance)
    }.clipShape(shape)
  }

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
      content.background { fill(glass: true) }
        .glassEffect(.regular.interactive(), in: shape)
    } else {
      content.background { fill(glass: false) }
        .overlay {
          shape.stroke(selected ? TransallTheme.accent : TransallTheme.inkSoft, lineWidth: 1)
        }
    }
  }
}
