import SwiftUI

enum TransallTheme {
  static let paper = Color(red: 0.957, green: 0.965, blue: 0.953)
  static let panel = Color(red: 0.984, green: 0.988, blue: 0.976)
  static let panelMuted = Color(red: 0.933, green: 0.953, blue: 0.933)
  static let ink = Color(red: 0.125, green: 0.145, blue: 0.133)
  static let inkSoft = Color(red: 0.282, green: 0.325, blue: 0.294)
  static let muted = Color(red: 0.4, green: 0.443, blue: 0.4)
  static let line = Color(red: 0.796, green: 0.839, blue: 0.8)
  static let lineStrong = Color(red: 0.667, green: 0.725, blue: 0.678)
  static let accent = Color(red: 0.702, green: 0.282, blue: 0.176)
  static let accentSoft = Color(red: 0.953, green: 0.839, blue: 0.792)
  static let source = Color(red: 0.184, green: 0.435, blue: 0.306)
  static let target = Color(red: 0.133, green: 0.243, blue: 0.361)
  static let warning = Color(red: 0.541, green: 0.392, blue: 0.157)
  static let danger = Color(red: 0.624, green: 0.216, blue: 0.216)

  static let formatColors: [String: Color] = [
    "pdf": accent,
    "word": Color(red: 0.192, green: 0.373, blue: 0.624),
    "translated_pdf": target,
    "ocr": Color(red: 0.416, green: 0.29, blue: 0.545),
    "ppt": Color(red: 0.651, green: 0.325, blue: 0.184),
    "excel": Color(red: 0.184, green: 0.451, blue: 0.341),
    "md": Color(red: 0.29, green: 0.369, blue: 0.447),
    "html": Color(red: 0.463, green: 0.384, blue: 0.235),
    "image": Color(red: 0.478, green: 0.306, blue: 0.4),
    "data": Color(red: 0.373, green: 0.42, blue: 0.208),
  ]
}

struct PaperGridBackground: View {
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
      context.stroke(path, with: .color(TransallTheme.ink.opacity(0.035)), lineWidth: 1)
    }
    .ignoresSafeArea()
    .accessibilityHidden(true)
  }
}

struct WorkbenchPanel<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .padding(16)
      .background(TransallTheme.panel)
      .overlay {
        RoundedRectangle(cornerRadius: 7)
          .stroke(TransallTheme.line, lineWidth: 1)
      }
      .clipShape(RoundedRectangle(cornerRadius: 7))
      .shadow(color: TransallTheme.ink.opacity(0.08), radius: 18, y: 8)
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
