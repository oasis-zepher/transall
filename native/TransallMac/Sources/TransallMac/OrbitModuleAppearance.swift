import SwiftUI

struct OrbitFormatRoles: Equatable {
  let source: Bool
  let target: Bool

  var description: String {
    "源格式\(source ? "可用" : "不支持")，输出格式\(target ? "可用" : "不支持")"
  }
}

// Both endpoints use the same path topology, so the rounded module continuously becomes
// the upper or lower half of the actual hourglass instead of cross-fading between shapes.
struct OrbitModuleShape: Shape {
  // A signed value morphs through the neutral module when switching chambers.
  // A discrete slot switch would mirror a partially stretched shape in one frame.
  nonisolated var amount: Double

  init(slot: FormatRouteSlot, amount: Double) {
    self.amount = (slot == .source ? 1 : -1) * amount
  }

  nonisolated var animatableData: Double {
    get { amount }
    set { amount = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let t = max(0, min(1, abs(amount)))
    let rx = min(0.5, 20 / max(1, rect.width))
    let ry = min(0.5, 20 / max(1, rect.height))
    func blend(_ first: Double, _ last: Double) -> Double { first + (last - first) * t }
    func p(_ x: Double, _ y: Double) -> CGPoint {
      CGPoint(
        x: rect.minX + rect.width * x,
        y: rect.minY + rect.height * (amount >= 0 ? y : 1 - y))
    }
    var path = Path()
    path.move(to: p(blend(rx, 0.12), 0))
    path.addLine(to: p(blend(1 - rx, 0.88), 0))
    path.addQuadCurve(to: p(1, blend(ry, 0.24)), control: p(1, 0))
    path.addCurve(
      to: p(blend(1, 0.58), blend(1 - ry, 1)),
      control1: p(1, 0.60), control2: p(blend(1, 0.58), blend(1 - ry, 0.76)))
    path.addQuadCurve(to: p(blend(1 - rx, 0.58), 1), control: p(blend(1, 0.58), 1))
    path.addLine(to: p(blend(rx, 0.42), 1))
    path.addQuadCurve(to: p(blend(0, 0.42), blend(1 - ry, 1)), control: p(blend(0, 0.42), 1))
    path.addCurve(
      to: p(0, blend(ry, 0.24)),
      control1: p(blend(0, 0.42), blend(1 - ry, 0.76)), control2: p(0, 0.60))
    path.addQuadCurve(to: p(blend(rx, 0.12), 0), control: p(0, 0))
    path.closeSubpath()
    return path
  }
}

enum OrbitDragGeometry {
  static func displayedPosition(
    _ position: CGPoint, docking: OrbitDockingTarget?, reduceMotion: Bool
  ) -> CGPoint {
    guard !reduceMotion, let docking, docking.compatibility == .compatible else { return position }
    let pull = max(0, min(1, docking.strength)) * 0.22
    return CGPoint(
      x: position.x + (docking.presentationCenter.x - position.x) * pull,
      y: position.y + (docking.presentationCenter.y - position.y) * pull)
  }

  static let approachDuration = 0.78
  static let retractDuration = 0.28
  static let chamberDuration = 0.64
  // Allow the reserved ring positions to finish their 480 ms redistribution before handoff.
  static let ringDuration = 0.48
}

// Keep the contour transition smooth while retaining the original gentle attraction.
// A fully morphed module still follows the pointer; exact placement happens only on release.
struct OrbitDragVisual: View, Animatable {
  nonisolated var morph: Double
  nonisolated var contraction: Double
  nonisolated var settleProgress: Double
  let anchor: CGPoint
  let destination: CGPoint
  let format: String
  let diameter: CGFloat
  let roles: OrbitFormatRoles
  let arrivalRoles: OrbitFormatRoles
  let layout: HourglassLayout
  nonisolated var ringAngle = 0.0
  var onRing = false
  var concealed = false
  nonisolated var sourceSupport = 1.0
  nonisolated var targetSupport = 1.0

  typealias GeometryAnimation = AnimatablePair<Double, AnimatablePair<Double, Double>>
  typealias ColorAnimation = AnimatablePair<Double, Double>
  nonisolated var animatableData:
    AnimatablePair<GeometryAnimation, AnimatablePair<Double, ColorAnimation>>
  {
    get {
      AnimatablePair(
        AnimatablePair(morph, AnimatablePair(contraction, settleProgress)),
        AnimatablePair(ringAngle, AnimatablePair(sourceSupport, targetSupport)))
    }
    set {
      morph = newValue.first.first
      contraction = newValue.first.second.first
      settleProgress = newValue.first.second.second
      ringAngle = newValue.second.first
      sourceSupport = newValue.second.second.first
      targetSupport = newValue.second.second.second
    }
  }

  var body: some View {
    let slot: FormatRouteSlot = morph < 0 ? .target : .source
    let docking = OrbitDockingTarget(
      slot: slot, frame: layout.slotFrame(slot),
      strength: abs(morph), compatibility: .compatible)
    let dimensions = docking.moduleSize(diameter: diameter, reduceMotion: false)
    let point =
      onRing
      ? CGPoint(
        x: layout.orbitSize / 2 + cos(ringAngle) * layout.orbitSize * 0.385,
        y: layout.orbitSize / 2 + sin(ringAngle) * layout.orbitSize * 0.385)
      : CGPoint(
        x: anchor.x + (destination.x - anchor.x) * settleProgress,
        y: anchor.y + (destination.y - anchor.y) * settleProgress)
    OrbitFormatButton(
      format: format, diameter: diameter, selected: abs(morph) > 0,
      roles: roles, enabled: true,
      concealed: concealed,
      previewRoles: arrivalRoles, previewAmount: settleProgress,
      supportOverride: [sourceSupport, targetSupport],
      moduleSize: CGSize(
        width: dimensions.width * (1 - 0.15 * contraction), height: dimensions.height),
      labelWidth: diameter, morphSlot: slot, morphAmount: abs(morph), action: {}
    )
    .position(OrbitDragGeometry.displayedPosition(point, docking: docking, reduceMotion: false))
    // The parent interpolates all geometry together; nested implicit animations would
    // lag behind it and detach the contour from the slot again.
    .transaction {
      $0.animation = nil
      $0.disablesAnimations = true
    }
  }
}

// One visual identity per format owns its native glass for both the ring and the drag.
// Pointer/keyboard targets remain separate clear geometry; they never paint another copy.
struct OrbitModuleMotion: Equatable {
  let docking: OrbitDockingTarget?
  let settling: Bool
  let progress: Double
  let anchor: CGPoint
  let destination: CGPoint
  let arrivalRoles: OrbitFormatRoles

  var duration: Double {
    settling
      ? (docking == nil ? OrbitDragGeometry.ringDuration : OrbitDragGeometry.chamberDuration)
      : (docking == nil ? OrbitDragGeometry.retractDuration : OrbitDragGeometry.approachDuration)
  }
}

struct OrbitStableModule: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let format: String
  let size: CGFloat
  let angle: Double
  let visible: Bool
  let motion: OrbitModuleMotion?
  let roles: OrbitFormatRoles
  let previewRoles: OrbitFormatRoles
  let previewAmount: Double
  @State private var continuousAngle: Double
  @State private var wasOnRing: Bool

  init(
    format: String, size: CGFloat, angle: Double, visible: Bool,
    motion: OrbitModuleMotion?, roles: OrbitFormatRoles,
    previewRoles: OrbitFormatRoles, previewAmount: Double
  ) {
    self.format = format
    self.size = size
    self.angle = angle
    self.visible = visible
    self.motion = motion
    self.roles = roles
    self.previewRoles = previewRoles
    self.previewAmount = previewAmount
    _continuousAngle = State(initialValue: angle)
    _wasOnRing = State(initialValue: motion == nil)
  }

  private var onRing: Bool { motion == nil }
  private var supports: [Double] {
    let arrival = motion?.arrivalRoles ?? previewRoles
    let amount = motion?.progress ?? previewAmount
    func blend(_ from: Bool, _ to: Bool) -> Double {
      let start = from ? 1.0 : 0.0
      return start + ((to ? 1.0 : 0.0) - start) * amount
    }
    return [blend(roles.source, arrival.source), blend(roles.target, arrival.target)]
  }

  var body: some View {
    let docking = motion?.docking
    OrbitDragVisual(
      morph: reduceMotion || docking?.compatibility != .compatible
        ? 0 : Double(docking?.strength ?? 0) * (docking?.slot == .target ? -1 : 1),
      contraction: reduceMotion || docking?.compatibility != .incompatible
        ? 0 : Double(docking?.strength ?? 0),
      settleProgress: motion?.progress ?? 0,
      anchor: motion?.anchor ?? .zero, destination: motion?.destination ?? .zero,
      format: format, diameter: NativeFormatOrbit.moduleDiameter(size: size),
      roles: onRing && previewAmount > 0 ? previewRoles : roles,
      arrivalRoles: motion?.arrivalRoles ?? roles,
      layout: HourglassLayout(orbitSize: size),
      ringAngle: onRing && wasOnRing ? continuousAngle : angle,
      onRing: onRing, concealed: !visible,
      sourceSupport: supports[0], targetSupport: supports[1]
    )
    .animation(
      reduceMotion
        ? nil : .easeInOut(duration: motion?.duration ?? OrbitDragGeometry.retractDuration),
      value: docking
    )
    .animation(
      reduceMotion
        ? nil : .easeInOut(duration: motion?.duration ?? OrbitDragGeometry.approachDuration),
      value: supports
    )
    .onChange(of: angle) { _, next in
      if onRing && wasOnRing && visible {
        withAnimation(reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.48)) {
          continuousAngle = NativeFormatOrbit.nearestAngle(next, to: continuousAngle)
        }
      } else {
        alignAngle()
      }
    }
    .onChange(of: onRing) { _, _ in alignAngle() }
  }

  private func alignAngle() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      continuousAngle = NativeFormatOrbit.nearestAngle(angle, to: continuousAngle)
      wasOnRing = onRing
    }
  }
}
