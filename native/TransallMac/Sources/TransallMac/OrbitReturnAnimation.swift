import SwiftUI

struct OrbitReleasedFormat: Equatable, Identifiable {
  let format: String
  let slot: FormatRouteSlot
  var id: String { format }
}

// Hover may advance only through the attached stage. A confirmed replacement continues
// this same presentation; an invalid or abandoned approach simply drives it back to zero.
struct OrbitReleasePresentation: Equatable {
  let item: OrbitReleasedFormat
  var progress: Double
  static let preparationLimit = 0.50
  static let settlementLimit = OrbitDeparturePath.separation - 0.02

  static func preparation(item: OrbitReleasedFormat, strength: CGFloat) -> Self {
    Self(item: item, progress: min(1, max(0, strength)) * preparationLimit)
  }

  var remainingDuration: Double {
    max(OrbitDragGeometry.ringDuration, (1 - progress) * OrbitDeparturePath.duration)
  }
}

struct OrbitReturnPlan: Equatable {
  let before: RouteSelection
  let after: RouteSelection
  let order: [String]
  let departures: [OrbitReleasedFormat]

  static func make(
    before: RouteSelection, after: RouteSelection, order: [String],
    draggedFormat: String? = nil, dropPoint: CGPoint? = nil, size: CGFloat
  ) -> Self {
    var released: [OrbitReleasedFormat] = []
    for slot in FormatRouteSlot.allCases {
      if let format = before[slot], after.source != format, after.target != format,
        !released.contains(where: { $0.format == format })
      {
        released.append(OrbitReleasedFormat(format: format, slot: slot))
      }
    }
    var visible = NativeFormatOrbit.remainingFormats(for: after, order: order)
      .filter { format in !released.contains(where: { $0.format == format }) }
    for item in released {
      let point = item.format == draggedFormat ? dropPoint : nil
      if let point {
        visible = inserting(item.format, into: visible, at: point, size: size)
      } else {
        // Reserve the outlet itself, rather than rotating a distant hidden gap to it.
        let index = item.slot == .source ? 0 : (visible.count + 1) / 2
        visible.insert(item.format, at: index)
      }
    }
    if released.count == 2, draggedFormat == nil,
      let upper = released.first(where: { $0.slot == .source }),
      let lower = released.first(where: { $0.slot == .target })
    {
      visible.removeAll { $0 == upper.format || $0 == lower.format }
      visible.insert(upper.format, at: 0)
      visible.insert(lower.format, at: (visible.count + 1) / 2)
    }
    return Self(
      before: before, after: after,
      order: visible + NativeFormatOrbit.formats.filter { !visible.contains($0) },
      departures: released.filter { $0.format != draggedFormat || dropPoint == nil })
  }

  // Preserve the circular neighbors chosen by the pointer, including the last/first gap.
  static func inserting(_ format: String, into order: [String], at point: CGPoint, size: CGFloat)
    -> [String]
  {
    var remaining = order.filter { $0 != format }
    guard !remaining.isEmpty else { return [format] }
    let turn = Double.pi * 2
    let angle = atan2(Double(point.y - size / 2), Double(point.x - size / 2)) + .pi / 2
    let normalized = (angle.truncatingRemainder(dividingBy: turn) + turn)
      .truncatingRemainder(dividingBy: turn)
    let preceding = min(
      remaining.count - 1, Int(floor(normalized / turn * Double(remaining.count))))
    remaining.insert(format, at: preceding + 1)
    return remaining
  }
}

struct OrbitDeparturePath {
  let slot: FormatRouteSlot
  let destination: CGPoint
  let layout: HourglassLayout

  static let separation = 0.62
  static let duration = 0.96
  var diameter: CGFloat { NativeFormatOrbit.moduleDiameter(size: layout.orbitSize) }
  var direction: CGFloat { slot == .source ? -1 : 1 }
  var mouth: CGPoint {
    CGPoint(x: layout.frame.midX, y: slot == .source ? layout.frame.minY : layout.frame.maxY)
  }

  static func smooth(_ value: Double) -> Double {
    let t = min(1, max(0, value))
    return t * t * (3 - 2 * t)
  }

  func point(at progress: Double) -> CGPoint {
    let release = CGPoint(x: mouth.x, y: mouth.y + direction * diameter * 0.66)
    if progress <= Self.separation {
      let t = Self.smooth(progress / Self.separation)
      return CGPoint(x: mouth.x, y: mouth.y + direction * diameter * 0.66 * t)
    }
    let t = Self.smooth((progress - Self.separation) / (1 - Self.separation))
    let u = 1 - t
    let outward = CGPoint(x: release.x, y: release.y + direction * diameter * 0.22)
    let approach = CGPoint(
      x: destination.x * 0.82 + release.x * 0.18,
      y: destination.y * 0.82 + release.y * 0.18)
    return CGPoint(
      x: u * u * u * release.x + 3 * u * u * t * outward.x + 3 * u * t * t * approach.x + t * t * t
        * destination.x,
      y: u * u * u * release.y + 3 * u * u * t * outward.y + 3 * u * t * t * approach.y + t * t * t
        * destination.y)
  }

  func moduleFrame(at progress: Double) -> CGRect {
    let growth = Self.smooth(progress / 0.36)
    let width = diameter * (0.12 + 0.88 * growth)
    let height = diameter * (0.08 + 0.92 * growth)
    let center = point(at: progress)
    return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
  }

  func neckWidth(at progress: Double) -> CGFloat {
    diameter * 0.58 * (1 - Self.smooth((progress - 0.24) / (Self.separation - 0.24)))
  }
}

// The bulb and narrowing neck are one continuous silhouette, filled with native glass.
// Until separation the silhouette is clipped at the chamber's outside lip: it emerges
// through that edge instead of carrying a half-hourglass across the new selection.
struct OrbitExtrusionShape: Shape {
  let departure: OrbitDeparturePath
  nonisolated var progress: Double
  nonisolated var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let bulb = departure.moduleFrame(at: progress)
    let rounding = OrbitDeparturePath.smooth((progress - 0.45) / 0.4)
    let radius = bulb.width / 2 + (min(20, bulb.width / 2) - bulb.width / 2) * rounding
    var result = RoundedRectangle(cornerRadius: radius).path(in: bulb)
    let width = departure.neckWidth(at: progress)
    if progress < OrbitDeparturePath.separation {
      let mouth = departure.mouth
      let center = departure.point(at: progress)
      let middle = (mouth.y + center.y) / 2
      var neck = Path()
      neck.move(to: CGPoint(x: mouth.x - width / 2, y: mouth.y))
      neck.addCurve(
        to: CGPoint(x: center.x - width * 0.45, y: center.y),
        control1: CGPoint(x: mouth.x - width * 0.10, y: middle),
        control2: CGPoint(x: center.x - width * 0.12, y: middle))
      neck.addLine(to: CGPoint(x: center.x + width * 0.45, y: center.y))
      neck.addCurve(
        to: CGPoint(x: mouth.x + width / 2, y: mouth.y),
        control1: CGPoint(x: center.x + width * 0.12, y: middle),
        control2: CGPoint(x: mouth.x + width * 0.10, y: middle))
      neck.closeSubpath()
      result = result.union(neck)
      let outside = CGRect(
        x: rect.minX, y: departure.slot == .source ? rect.minY : mouth.y,
        width: rect.width,
        height: departure.slot == .source ? mouth.y - rect.minY : rect.maxY - mouth.y)
      result = result.intersection(Path(outside))
    }
    return result
  }
}

struct OrbitReturningModule: View, Animatable {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  nonisolated var progress: Double
  let format: String
  let diameter: CGFloat
  let roles: OrbitFormatRoles
  let path: OrbitDeparturePath

  nonisolated var animatableData: Double {
    get { progress }
    set { progress = newValue }
  }

  private var glass: Bool {
    if #available(macOS 26.0, *) { return !reduceTransparency && contrast != .increased }
    return false
  }

  var body: some View {
    let shape = OrbitExtrusionShape(departure: path, progress: progress)
    let bulb = path.moduleFrame(at: progress)
    let available = glass ? Color.clear : TransallTheme.orbitVacancy
    let unavailable = Color(nsColor: .textBackgroundColor)
    let surface = LinearGradient(
      stops: [
        .init(color: roles.source ? available : unavailable, location: 0),
        .init(color: roles.source ? available : unavailable, location: 0.28),
        .init(color: roles.target ? available : unavailable, location: 0.72),
        .init(color: roles.target ? available : unavailable, location: 1),
      ], startPoint: .top, endPoint: .bottom)
    let contents = ZStack {
      if !glass { shape.fill(TransallTheme.orbitVacancy) }
      surface.frame(width: bulb.width, height: bulb.height).position(x: bulb.midX, y: bulb.midY)
        .opacity(OrbitDeparturePath.smooth((progress - 0.48) / 0.4))
      VStack(spacing: 7) {
        Image(systemName: NativeFormatOrbit.symbol(format)).font(.system(size: diameter * 0.24))
          .opacity(OrbitDeparturePath.smooth((progress - 0.10) / 0.24))
        Text(NativeFormatOrbit.title(format))
          .font(.system(size: diameter < 75 ? 11 : 13, weight: .medium))
          .lineLimit(1).minimumScaleFactor(0.8)
          .opacity(OrbitDeparturePath.smooth((progress - 0.54) / 0.22))
      }.foregroundStyle(TransallTheme.ink).frame(width: diameter)
        .position(x: bulb.midX, y: bulb.midY)
    }.frame(width: path.layout.orbitSize, height: path.layout.orbitSize).clipShape(shape)
    Group {
      if #available(macOS 26.0, *), glass {
        contents.glassEffect(.regular.interactive(), in: shape)
      } else {
        contents.overlay { shape.stroke(TransallTheme.inkSoft, lineWidth: 1) }
      }
    }
    .opacity(OrbitDeparturePath.smooth(progress / 0.08))
    .transaction { $0.animation = nil }
  }
}

// Rotate the evenly spaced ring only as far as necessary to clear the entire attached
// extrusion corridor. Hidden incoming/outgoing modules reserve their positions but do not
// obstruct the outlet. Keeping one phase preserves circular order and equal spacing.
enum OrbitExitClearance {
  static func phase(
    formats: [String], hidden: Set<String>, slots: Set<FormatRouteSlot>, size: CGFloat
  ) -> Double {
    guard !formats.isEmpty, !slots.isEmpty else { return 0 }
    let layout = HourglassLayout(orbitSize: size)
    let diameter = NativeFormatOrbit.moduleDiameter(size: size)
    let corridors = slots.map { slot in
      let mouth = slot == .source ? layout.frame.minY : layout.frame.maxY
      return CGRect(
        x: size / 2 - diameter / 2,
        y: slot == .source ? mouth - diameter * 1.16 : mouth,
        width: diameter, height: diameter * 1.16
      ).insetBy(dx: -8, dy: -8)
    }
    var best = 0.0
    var bestOverlap = Double.infinity
    // At most half a module spacing: clearance must never spin the whole ring.
    let limit = .pi / Double(formats.count)
    for degree in 0...Int(ceil(limit * 180 / .pi)) {
      for sign in (degree == 0 ? [1.0] : [1.0, -1.0]) {
        let phase = min(limit, Double(degree) * .pi / 180) * sign
        var overlap = 0.0
        for format in formats where !hidden.contains(format) {
          let angle = NativeFormatOrbit.angle(of: format, among: formats) + phase
          let node = CGRect(
            x: size / 2 + cos(angle) * size * 0.385 - diameter / 2,
            y: size / 2 + sin(angle) * size * 0.385 - diameter / 2,
            width: diameter, height: diameter)
          for corridor in corridors {
            let intersection = node.intersection(corridor)
            if !intersection.isNull { overlap += intersection.width * intersection.height }
          }
        }
        if overlap == 0 { return phase }
        if overlap < bestOverlap {
          bestOverlap = overlap
          best = phase
        }
      }
    }
    return best
  }
}
