import PDFKit

struct PDFTranslationRegion: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Sendable {
    case nativeText
    case imageOCR
  }

  let id: String
  let pageIndex: Int
  let kind: Kind
  let bounds: CGRect
  let sourceText: String
  let preferredFontSize: CGFloat
  var bold: Bool? = nil
  var centered: Bool? = nil
  var textColor: [Double]? = nil
  var preserveOriginal: Bool? = nil
  // Ordered IDs sharing a sentence across text boxes, columns or pages. Nil keeps old caches readable.
  var continuationGroup: [String]? = nil
  var continuationVersion: Int? = nil
}

struct PDFLayoutTranslationReport: Equatable, Sendable {
  let pageCount: Int
  let nativeRegionCount: Int
  let imageOCRRegionCount: Int
  let overflowRegionIDs: [String]
  var supplementedRegionIDs: [String] = []
}

enum PDFLayoutTranslation {
  static let bilingualCreator = "Transall bilingual side by side v2"
  static let bilingualGutter: CGFloat = 16
  static let supplementMarker = "Transall layout supplements v1"

  struct OCRObservation: Equatable, Sendable {
    let text: String
    let normalizedBounds: CGRect
    let confidence: Float
  }

  typealias OCRRecognizer = @Sendable (CGImage, [String]) throws -> [OCRObservation]

  static let maximumRegions = 10_000
  static let minimumOCRConfidence: Float = 0.35
  static let minimumTranslationFontSize: CGFloat = 8
  static let minimumTranslationFontScale: CGFloat = 0.75

  struct NativeLine {
    let text: String
    let bounds: CGRect
    let fontSize: CGFloat
    var bold = false
    var textColor: [Double]? = nil
    var preserveOriginal = false
  }

  struct RenderedPage {
    let image: CGImage
    let pageToImageTransform: CGAffineTransform
  }

  struct PageBackgroundSampler {
    let bitmap: NSBitmapImageRep
    let pageToImageTransform: CGAffineTransform

    init(renderedPage: RenderedPage) {
      bitmap = NSBitmapImageRep(cgImage: renderedPage.image)
      pageToImageTransform = renderedPage.pageToImageTransform
    }

    func color(around bounds: CGRect) -> NSColor {
      let offset = max(1.5, min(bounds.width, bounds.height) * 0.08)
      let fractions: [CGFloat] = [0.15, 0.35, 0.5, 0.65, 0.85]
      var samples: [NSColor] = []
      for fraction in fractions {
        samples.append(
          contentsOf: [
            color(at: CGPoint(x: bounds.minX + bounds.width * fraction, y: bounds.minY - offset)),
            color(at: CGPoint(x: bounds.minX + bounds.width * fraction, y: bounds.maxY + offset)),
            color(at: CGPoint(x: bounds.minX - offset, y: bounds.minY + bounds.height * fraction)),
            color(at: CGPoint(x: bounds.maxX + offset, y: bounds.minY + bounds.height * fraction)),
          ].compactMap { $0 })
      }
      guard !samples.isEmpty else { return .white }
      let reds = samples.map(\.redComponent).sorted()
      let greens = samples.map(\.greenComponent).sorted()
      let blues = samples.map(\.blueComponent).sorted()
      let middle = samples.count / 2
      return NSColor(
        deviceRed: reds[middle], green: greens[middle], blue: blues[middle], alpha: 1)
    }

    private func color(at point: CGPoint) -> NSColor? {
      guard bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else {
        return nil
      }
      let imagePoint = point.applying(pageToImageTransform)
      guard imagePoint.x >= 0, imagePoint.y >= 0,
        imagePoint.x < CGFloat(bitmap.pixelsWide), imagePoint.y < CGFloat(bitmap.pixelsHigh)
      else {
        return nil
      }
      let x = min(bitmap.pixelsWide - 1, max(0, Int(imagePoint.x)))
      let y = min(bitmap.pixelsHigh - 1, max(0, bitmap.pixelsHigh - 1 - Int(imagePoint.y)))
      return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
    }
  }
}
