import AppKit
import SwiftUI

enum TransallTheme {
  static let paper = adaptive((0.957, 0.965, 0.953), (0.105, 0.12, 0.113))
  static let panel = adaptive((0.984, 0.988, 0.976), (0.155, 0.173, 0.161))
  static let panelMuted = adaptive((0.933, 0.953, 0.933), (0.19, 0.212, 0.197))
  static let ink = Color(nsColor: .labelColor)
  static let inkSoft = adaptive((0.282, 0.325, 0.294), (0.79, 0.825, 0.80))
  static let muted = adaptive((0.4, 0.443, 0.4), (0.66, 0.71, 0.68))
  static let line = adaptive((0.796, 0.839, 0.8), (0.285, 0.325, 0.30))
  static let lineStrong = adaptive((0.667, 0.725, 0.678), (0.46, 0.53, 0.48))
  static let accent = adaptive((0.702, 0.282, 0.176), (0.96, 0.60, 0.43))
  static let accentSoft = adaptive((0.953, 0.839, 0.792), (0.36, 0.24, 0.20))
  static let source = adaptive((0.184, 0.435, 0.306), (0.48, 0.82, 0.61))
  static let target = adaptive((0.133, 0.243, 0.361), (0.59, 0.76, 0.94))
  static let warning = adaptive((0.541, 0.392, 0.157), (0.92, 0.75, 0.40))
  static let danger = adaptive((0.624, 0.216, 0.216), (0.98, 0.58, 0.55))
  static let onAccent = adaptive((1, 1, 1), (0.13, 0.10, 0.085))

  private static func adaptive(
    _ light: (Double, Double, Double), _ dark: (Double, Double, Double)
  ) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: 1)
      })
  }

  static let formatColors: [String: Color] = [
    "pdf": accent,
    "word": adaptive((0.192, 0.373, 0.624), (0.57, 0.73, 0.96)),
    "translated_pdf": target,
    "ocr": adaptive((0.416, 0.29, 0.545), (0.78, 0.65, 0.90)),
    "ppt": adaptive((0.651, 0.325, 0.184), (0.95, 0.67, 0.48)),
    "excel": source,
    "md": adaptive((0.29, 0.369, 0.447), (0.65, 0.76, 0.86)),
    "html": adaptive((0.463, 0.384, 0.235), (0.86, 0.77, 0.56)),
    "image": adaptive((0.478, 0.306, 0.4), (0.88, 0.64, 0.78)),
    "data": adaptive((0.373, 0.42, 0.208), (0.73, 0.80, 0.49)),
  ]
}

struct PaperGridBackground: View {
  @Environment(\.colorSchemeContrast) private var contrast
  var body: some View {
    Canvas { context, size in
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(TransallTheme.paper))
      var path = Path()
      let spacing: CGFloat = 32
      for x in stride(from: CGFloat.zero, through: size.width, by: spacing) {
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: size.height))
      }
      for y in stride(from: CGFloat.zero, through: size.height, by: spacing) {
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: size.width, y: y))
      }
      context.stroke(
        path, with: .color(TransallTheme.ink.opacity(contrast == .increased ? 0 : 0.025)),
        lineWidth: 1)
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }
}

struct WorkbenchPanel<Content: View>: View {
  @Environment(\.colorSchemeContrast) private var contrast
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(16)
      .background(TransallTheme.panel)
      .overlay {
        RoundedRectangle(cornerRadius: 16)
          .stroke(contrast == .increased ? TransallTheme.inkSoft : TransallTheme.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 16))
  }
}

struct SectionLabel: View {
  let text: String

  var body: some View {
    Text(text.uppercased())
      .font(.system(.caption, design: .rounded, weight: .semibold))
      .tracking(1.5)
      .foregroundStyle(TransallTheme.muted)
  }
}

// Glass is reserved for controls. Document and form surfaces remain opaque.
struct TransallControlGroup<Content: View>: View {
  let spacing: CGFloat
  let content: Content

  init(spacing: CGFloat = 8, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if #available(macOS 26.0, *) {
      GlassEffectContainer(spacing: spacing) { content }
    } else {
      content
    }
  }
}

struct TransallGlassBar<Content: View>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let content: Content

  init(@ViewBuilder content: () -> Content) { self.content = content() }

  var body: some View {
    if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
      content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    } else {
      content
        .background(TransallTheme.panel, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
          RoundedRectangle(cornerRadius: 16)
            .stroke(
              contrast == .increased ? TransallTheme.inkSoft : TransallTheme.line, lineWidth: 1)
        }
    }
  }
}

struct QuietButtonStyle: PrimitiveButtonStyle {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
      Button(configuration).buttonStyle(.glass).buttonBorderShape(.capsule)
        .tint(nil).controlSize(.regular)
    } else {
      Button(configuration).buttonStyle(SolidControlButtonStyle(prominent: false))
    }
  }
}

struct PrimaryButtonStyle: PrimitiveButtonStyle {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func makeBody(configuration: Configuration) -> some View {
    if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
      Button(configuration).buttonStyle(.glassProminent).tint(TransallTheme.accent)
        .controlSize(.large)
    } else {
      Button(configuration).buttonStyle(SolidControlButtonStyle(prominent: true))
    }
  }
}

private struct SolidControlButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  let prominent: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(prominent ? .callout.weight(.semibold) : .caption.weight(.semibold))
      .foregroundStyle(
        !isEnabled ? TransallTheme.muted : prominent ? TransallTheme.onAccent : TransallTheme.ink
      )
      .padding(.horizontal, prominent ? 16 : 11)
      .padding(.vertical, prominent ? 9 : 6)
      .background(
        prominent && isEnabled ? TransallTheme.accent : TransallTheme.panel,
        in: Capsule()
      )
      .overlay {
        Capsule().strokeBorder(
          prominent && isEnabled ? TransallTheme.accent : TransallTheme.lineStrong, lineWidth: 1)
      }
      .brightness(configuration.isPressed && isEnabled ? -0.06 : 0)
  }
}
