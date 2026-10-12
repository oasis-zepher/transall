import SwiftUI

enum NativeFormatOrbit {
  static func moduleDiameter(size: CGFloat) -> CGFloat { min(88, floor(size * 0.14) - 1) }
  static let formats = [
    "pdf", "translated_pdf", "ocr", "md", "html", "image", "data", "word", "ppt", "excel",
  ]

  static func remainingFormats(
    for selection: RouteSelection, lifting format: String? = nil,
    order: [String] = NativeFormatOrbit.formats
  )
    -> [String]
  {
    order.filter { $0 != selection.source && $0 != selection.target && $0 != format }
  }

  static func angle(of format: String, among remaining: [String]) -> Double {
    let index = remaining.firstIndex(of: format) ?? 0
    return Double(index) / Double(max(1, remaining.count)) * .pi * 2 - .pi / 2
  }

  static func nearestAngle(_ angle: Double, to reference: Double) -> Double {
    reference + atan2(sin(angle - reference), cos(angle - reference))
  }

  static func candidateSlots(for selection: RouteSelection, activeSlot: FormatRouteSlot)
    -> [FormatRouteSlot]
  {
    if selection.source == nil && selection.target == nil { return [.source, .target] }
    return [activeSlot]
  }

  // Strength grows continuously as the pointer approaches an empty slot, without a hard jump.
  static func dockingStrength(at point: CGPoint, to frame: CGRect, reach: CGFloat = 64) -> CGFloat {
    let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
    let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
    let distance = hypot(dx, dy)
    let proximity = max(0, min(1, 1 - distance / max(1, reach)))
    return proximity * proximity * (3 - 2 * proximity)
  }

  // Entering through the narrow waist takes progress through the chamber, instead of
  // becoming fully stretched as soon as the pointer crosses its rectangular hit edge.
  static func dockingStrength(at point: CGPoint, to frame: CGRect, slot: FormatRouteSlot) -> CGFloat
  {
    let base = dockingStrength(at: point, to: frame)
    let throughWaist = slot == .source ? point.y > frame.midY : point.y < frame.midY
    guard throughWaist else { return base }
    let distance = slot == .source ? frame.maxY + 64 - point.y : point.y - frame.minY + 64
    let t = min(1, max(0, distance / (64 + frame.height / 2)))
    let eased = t * t * (3 - 2 * t)
    return base * eased * eased
  }

  static func title(_ format: String) -> String {
    switch format {
    case "translated_pdf": "译文 PDF"
    case "ocr": "OCR"
    default: WorkbenchTask.sourceTitle(format)
    }
  }

  static func symbol(_ format: String) -> String {
    switch format {
    case "word": "doc.text"
    case "ppt": "rectangle.on.rectangle"
    case "excel": "tablecells"
    case "pdf": "doc.richtext"
    case "translated_pdf": "character.bubble"
    case "ocr": "text.viewfinder"
    case "md": "doc.plaintext"
    case "html": "chevron.left.forwardslash.chevron.right"
    case "image": "photo"
    default: "doc.text"
    }
  }
}
