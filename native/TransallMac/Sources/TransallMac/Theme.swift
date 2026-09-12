import AppKit
import SwiftUI

enum TransallTheme {
  static let paper = Color(nsColor: .windowBackgroundColor)
  static let panel = Color(nsColor: .controlBackgroundColor)
  static let orbitVacancy = Color(nsColor: .controlColor)
  static let panelMuted = Color(nsColor: .underPageBackgroundColor)
  static let ink = Color.primary
  static let inkSoft = Color.secondary
  static let muted = Color.secondary
  static let line = Color(nsColor: .separatorColor)
  static let lineStrong = Color(nsColor: .separatorColor)
  static let accent = Color(nsColor: .controlAccentColor)
  static let accentSoft = Color(nsColor: .controlAccentColor).opacity(0.12)
  static let source = Color(nsColor: .systemGreen)
  static let target = Color(nsColor: .controlAccentColor)
  static let warning = Color(nsColor: .systemOrange)
  static let danger = Color(nsColor: .systemRed)
}

struct SectionLabel: View {
  let text: String
  var body: some View {
    Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
      Button(configuration).buttonStyle(.glass)
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
        .controlSize(.regular)
    } else {
      Button(configuration).buttonStyle(SolidControlButtonStyle(prominent: true))
    }
  }
}

private struct SolidControlButtonStyle: PrimitiveButtonStyle {
  let prominent: Bool
  func makeBody(configuration: Configuration) -> some View {
    if prominent {
      Button(configuration).buttonStyle(.borderedProminent)
    } else {
      Button(configuration).buttonStyle(.bordered)
    }
  }
}
