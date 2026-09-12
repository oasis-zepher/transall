import SwiftUI

enum OrbitDockingCompatibility {
  case compatible, incompatible
}

struct OrbitDockingTarget: Equatable {
  let slot: FormatRouteSlot
  let frame: CGRect
  let strength: CGFloat
  let compatibility: OrbitDockingCompatibility

  // The hit region excludes 16 points beside the waist; the visible half includes them.
  var presentationFrame: CGRect {
    CGRect(
      x: frame.minX, y: frame.minY - (slot == .target ? 16 : 0),
      width: frame.width, height: frame.height + 16)
  }

  var presentationCenter: CGPoint {
    CGPoint(x: presentationFrame.midX, y: presentationFrame.midY)
  }

  func moduleSize(diameter: CGFloat, reduceMotion: Bool) -> CGSize {
    let amount = reduceMotion ? 0 : max(0, min(1, strength))
    switch compatibility {
    case .compatible:
      return CGSize(
        width: diameter + (frame.width - diameter) * amount,
        height: diameter + (frame.height + 16 - diameter) * amount)
    case .incompatible:
      return CGSize(width: diameter * (1 - 0.15 * amount), height: diameter)
    }
  }
}

struct HourglassLayout {
  let orbitSize: CGFloat

  var frame: CGRect {
    let width = min(200, orbitSize * 0.34)
    return CGRect(x: (orbitSize - width) / 2, y: orbitSize / 2 - 84, width: width, height: 168)
  }

  func slotFrame(_ slot: FormatRouteSlot) -> CGRect {
    CGRect(
      x: frame.minX, y: orbitSize / 2 + (slot == .source ? -84 : 16),
      width: frame.width, height: 68)
  }

  func chamberFrame(_ slot: FormatRouteSlot) -> CGRect {
    OrbitDockingTarget(
      slot: slot, frame: slotFrame(slot), strength: 1,
      compatibility: .compatible
    ).presentationFrame
  }

  func slot(at point: CGPoint) -> FormatRouteSlot? {
    guard HourglassShape().path(in: frame).contains(point) else { return nil }
    return FormatRouteSlot.allCases.first { slotFrame($0).contains(point) }
  }

  var flipCenter: CGPoint {
    CGPoint(x: orbitSize / 2 - frame.width * 0.32 - 22, y: orbitSize / 2)
  }

  var clearCenter: CGPoint {
    CGPoint(x: orbitSize - flipCenter.x, y: orbitSize / 2)
  }
}

struct HourglassShape: Shape {
  nonisolated var rotation = 0.0

  nonisolated var animatableData: Double {
    get { rotation }
    set { rotation = newValue }
  }

  func path(in rect: CGRect) -> Path {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }
    var path = Path()
    path.move(to: point(0.12, 0))
    path.addLine(to: point(0.88, 0))
    path.addQuadCurve(to: point(1, 0.12), control: point(1, 0))
    path.addCurve(to: point(0.58, 0.5), control1: point(1, 0.30), control2: point(0.58, 0.38))
    path.addCurve(to: point(1, 0.88), control1: point(0.58, 0.62), control2: point(1, 0.70))
    path.addQuadCurve(to: point(0.88, 1), control: point(1, 1))
    path.addLine(to: point(0.12, 1))
    path.addQuadCurve(to: point(0, 0.88), control: point(0, 1))
    path.addCurve(to: point(0.42, 0.5), control1: point(0, 0.70), control2: point(0.42, 0.62))
    path.addCurve(to: point(0, 0.12), control1: point(0.42, 0.38), control2: point(0, 0.30))
    path.addQuadCurve(to: point(0.12, 0), control: point(0, 0))
    path.closeSubpath()
    return path.applying(
      CGAffineTransform(translationX: rect.midX, y: rect.midY)
        .rotated(by: rotation * .pi / 180)
        .translatedBy(x: -rect.midX, y: -rect.midY))
  }
}

struct HourglassSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  let rotation: Double

  func body(content: Content) -> some View {
    let shape = HourglassShape(rotation: rotation)
    if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
      content.glassEffect(.regular.interactive(), in: shape)
    } else {
      content.background {
        shape.fill(TransallTheme.orbitVacancy).overlay {
          shape.stroke(
            contrast == .increased ? TransallTheme.inkSoft : TransallTheme.line, lineWidth: 1)
        }
      }
    }
  }
}

struct HourglassChamberShape: Shape {
  let slot: FormatRouteSlot

  func path(in rect: CGRect) -> Path {
    HourglassShape().path(
      in: CGRect(
        x: rect.minX, y: rect.minY - (slot == .source ? 0 : 100),
        width: rect.width, height: 168))
  }
}

struct HourglassFlipPresentation {
  let id = UUID()
  let selection: RouteSelection
}

// Only the position rotates. Format labels and the fixed source/target captions stay upright.
struct HourglassFlipPlacement: AnimatableModifier {
  nonisolated var angle: Double
  let slot: FormatRouteSlot
  let center: CGPoint

  nonisolated var animatableData: Double {
    get { angle }
    set { angle = newValue }
  }

  func body(content: Content) -> some View {
    let distance: CGFloat = slot == .source ? -50 : 50
    let radians = angle * .pi / 180
    content.position(
      x: center.x - sin(radians) * distance,
      y: center.y + cos(radians) * distance + 9)
  }
}
