import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Vision

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

  static func isSideBySideBilingual(_ url: URL) -> Bool {
    PDFDocument(url: url)?.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String
      == bilingualCreator
  }

  static func pairOriginalAndTranslation(inputURL: URL, outputURL: URL) throws {
    guard let original = PDFDocument(url: inputURL), let translated = PDFDocument(url: outputURL),
      let originalPDF = CGPDFDocument(inputURL as CFURL),
      let translatedPDF = CGPDFDocument(outputURL as CFURL),
      original.pageCount > 0,
      original.pageCount == translated.pageCount
        || (original.pageCount < translated.pageCount
          && translated.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String
            == supplementMarker)
    else { throw NativeDocumentError.processing("双语对照需要原文与译文逐页对应。") }
    let paired = PDFDocument()
    paired.documentAttributes = [PDFDocumentAttribute.creatorAttribute: bilingualCreator]
    var transforms: [[CGAffineTransform]] = []
    for index in 0..<original.pageCount {
      try Task.checkCancellation()
      guard let left = originalPDF.page(at: index + 1),
        let right = translatedPDF.page(at: index + 1)
      else { throw NativeDocumentError.processing("无法读取双语对照页面。") }
      let crop = left.getBoxRect(.cropBox)
      let quarterTurn = abs(left.rotationAngle % 180) == 90
      let size = quarterTurn ? CGSize(width: crop.height, height: crop.width) : crop.size
      guard size.width > 0, size.height > 0 else {
        throw NativeDocumentError.processing("双语对照页面尺寸无效。")
      }
      var media = CGRect(x: 0, y: 0, width: size.width * 2 + bilingualGutter, height: size.height)
      let data = NSMutableData()
      guard let consumer = CGDataConsumer(data: data as CFMutableData),
        let context = CGContext(consumer: consumer, mediaBox: &media, nil)
      else { throw NativeDocumentError.processing("无法创建左右对照 PDF。") }
      context.beginPDFPage(nil)
      context.setFillColor(NSColor.white.cgColor)
      context.fill(media)
      var pageTransforms: [CGAffineTransform] = []
      for (side, page) in [left, right].enumerated() {
        let pane = CGRect(
          x: CGFloat(side) * (size.width + bilingualGutter), y: 0,
          width: size.width, height: size.height)
        let transform = page.getDrawingTransform(
          .cropBox, rect: pane, rotate: 0, preserveAspectRatio: true)
        pageTransforms.append(transform)
        context.saveGState()
        context.clip(to: pane)
        context.concatenate(transform)
        context.drawPDFPage(page)
        context.restoreGState()
      }
      context.endPDFPage()
      context.closePDF()
      guard let rendered = PDFDocument(data: data as Data),
        let page = rendered.page(at: 0)?.copy() as? PDFPage
      else { throw NativeDocumentError.processing("无法组装左右对照页面。") }
      paired.insert(page, at: paired.pageCount)
      transforms.append(pageTransforms)
    }
    // Reattach annotations in the coordinate system of their left/right panel.
    for (side, document) in [original, translated].enumerated() {
      for index in 0..<original.pageCount {
        guard let sourcePage = document.page(at: index), let page = paired.page(at: index) else {
          continue
        }
        for annotation in sourcePage.annotations {
          guard let copy = annotation.copy() as? PDFAnnotation else { continue }
          copy.bounds = annotation.bounds.applying(transforms[index][side])
          remapDestination(
            of: copy, from: annotation, sourceDocument: document,
            transformPoint: { point, targetIndex in
              targetIndex < transforms.count ? point.applying(transforms[targetIndex][side]) : point
            },
            targetPage: { paired.page(at: $0) })
          page.addAnnotation(copy)
        }
      }
    }
    for index in original.pageCount..<translated.pageCount {
      guard let note = translated.page(at: index)?.copy() as? PDFPage else {
        throw NativeDocumentError.processing("无法保留补充译文页面。")
      }
      paired.insert(note, at: paired.pageCount)
    }
    guard let data = paired.dataRepresentation() else {
      throw NativeDocumentError.processing("无法生成左右对照 PDF。")
    }
    try data.write(to: outputURL, options: .atomic)
  }

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

  private struct NativeLine {
    let text: String
    let bounds: CGRect
    let fontSize: CGFloat
    var bold = false
    var textColor: [Double]? = nil
    var preserveOriginal = false
  }

  private struct RenderedPage {
    let image: CGImage
    let pageToImageTransform: CGAffineTransform
  }

  private struct PageBackgroundSampler {
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

  static func extractRegions(
    document: PDFDocument,
    rasterDocument: CGPDFDocument,
    languages: [String],
    recognizer: OCRRecognizer? = nil
  ) throws -> [PDFTranslationRegion] {
    guard document.pageCount == rasterDocument.numberOfPages else {
      throw NativeDocumentError.invalidFile("PDF 文字层与页面图像数量不一致。")
    }
    let recognize = recognizer ?? recognizeText
    var result: [PDFTranslationRegion] = []
    result.reserveCapacity(min(maximumRegions, document.pageCount * 24))

    for pageIndex in 0..<document.pageCount {
      try Task.checkCancellation()
      guard let page = document.page(at: pageIndex),
        let rasterPage = rasterDocument.page(at: pageIndex + 1)
      else {
        throw NativeDocumentError.invalidFile("无法读取 PDF 的第 \(pageIndex + 1) 页。")
      }
      let pageBounds = page.bounds(for: .cropBox).intersection(page.bounds(for: .mediaBox))
      let native = nativeRegions(page: page, pageIndex: pageIndex, pageBounds: pageBounds)
      result.append(contentsOf: native)
      guard result.count <= maximumRegions else {
        throw NativeDocumentError.processingLimit(
          "PDF 中可翻译的文字区域超过 \(maximumRegions.formatted()) 个。",
          recoverySuggestion: "请拆分 PDF 后分批翻译。")
      }

      guard let renderedPage = render(page: rasterPage, maximumDimension: 2_400) else {
        throw NativeDocumentError.processing("无法渲染 PDF 的第 \(pageIndex + 1) 页以补充图片文字。")
      }
      let observations = try recognize(renderedPage.image, languages)
      let imageSize = CGSize(
        width: renderedPage.image.width, height: renderedPage.image.height)
      let imageToPageTransform = renderedPage.pageToImageTransform.inverted()
      var imageRegionNumber = 0
      for observation in observations {
        try Task.checkCancellation()
        let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, observation.confidence >= minimumOCRConfidence else { continue }
        let imageBounds = CGRect(
          x: observation.normalizedBounds.minX * imageSize.width,
          y: observation.normalizedBounds.minY * imageSize.height,
          width: observation.normalizedBounds.width * imageSize.width,
          height: observation.normalizedBounds.height * imageSize.height)
        let bounds = imageBounds.applying(imageToPageTransform).intersection(pageBounds)
        guard bounds.width >= 2, bounds.height >= 2 else { continue }
        let normalizedText = normalizedForDeduplication(text)
        if native.contains(where: {
          if $0.preserveOriginal == true {
            guard overlapRatio(bounds, $0.bounds) >= 0.45 else { return false }
            if normalizedForDeduplication($0.sourceText).contains(normalizedText) { return true }
            // PDFKit returns zero character boxes for some rotated glyphs. A spatial
            // selection still identifies the native stamp fragment (e.g. OCR "SSI", native "ESS").
            guard let selection = page.selection(for: bounds), let selected = selection.string
            else {
              return false
            }
            let fragment = normalizedForDeduplication(selected)
            return !fragment.isEmpty && normalizedForDeduplication($0.sourceText).contains(fragment)
              && overlapRatio(bounds, selection.bounds(for: page)) >= 0.55
          }
          let overlap = overlapRatio(bounds, $0.bounds)
          let nativeText = normalizedForDeduplication($0.sourceText)
          return overlap >= 0.8 || (overlap >= 0.45 && nativeText.contains(normalizedText))
            || duplicatesNativeLine(text, bounds: bounds, native: $0)
        }) {
          continue
        }
        if result.contains(where: {
          $0.pageIndex == pageIndex && $0.kind == .imageOCR
            && overlapRatio(bounds, $0.bounds) >= 0.55
        }) {
          continue
        }

        imageRegionNumber += 1
        result.append(
          PDFTranslationRegion(
            id: regionID(pageIndex: pageIndex, kind: .imageOCR, number: imageRegionNumber),
            pageIndex: pageIndex,
            kind: .imageOCR,
            bounds: bounds,
            sourceText: text,
            preferredFontSize: max(5, min(24, bounds.height * 0.72))))
        guard result.count <= maximumRegions else {
          throw NativeDocumentError.processingLimit(
            "PDF 中可翻译的文字区域超过 \(maximumRegions.formatted()) 个。",
            recoverySuggestion: "请拆分 PDF 后分批翻译。")
        }
      }
    }
    let pageBounds = (0..<document.pageCount).compactMap {
      document.page(at: $0)?.bounds(for: .cropBox)
    }
    return linkPageContinuations(result, pageBounds: pageBounds)
  }

  static func linkPageContinuations(
    _ regions: [PDFTranslationRegion], pageBounds: [CGRect]
  ) -> [PDFTranslationRegion] {
    var result = regions.map { region in
      var value = region
      value.continuationGroup = nil
      value.continuationVersion = nil
      return value
    }
    let pages = Dictionary(grouping: regions.indices, by: { regions[$0].pageIndex })
    func normalized(_ text: String) -> String {
      text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let repeated = Dictionary(
      grouping: regions.filter {
        guard pageBounds.indices.contains($0.pageIndex), $0.sourceText.count < 180 else {
          return false
        }
        let box = pageBounds[$0.pageIndex]
        return $0.bounds.midY < box.minY + box.height * 0.12
          || $0.bounds.midY > box.maxY - box.height * 0.12
      },
      by: {
        normalized($0.sourceText)
      }
    ).filter { Set($0.value.map(\.pageIndex)).count > 1 }
    func isCaption(_ text: String) -> Bool {
      text.range(
        of: #"(?i)^\s*(?:fig(?:ure)?\.?\s*\d|table\s*\d|图\s*\d|表\s*\d)"#,
        options: .regularExpression) != nil
    }
    func bodyOrder(_ page: Int) -> [Int] {
      let box = pageBounds[page]
      let available = pages[page, default: []].filter { regions[$0].preserveOriginal != true }
      // OCR is body text only on pages without a usable native text layer. This
      // avoids treating labels inside a figure as the next paragraph.
      let native = available.filter { regions[$0].kind == .nativeText }
      let candidates = native.isEmpty ? available.filter { regions[$0].kind == .imageOCR } : native
      let fonts = candidates.filter { regions[$0].sourceText.count >= 80 }
        .map { regions[$0].preferredFontSize }.sorted()
      let bodyFont = fonts.isEmpty ? CGFloat(0) : fonts[fonts.count / 2]
      // Table titles and notes delimit an obstacle in the reading stream, not prose.
      let tableZones = candidates.compactMap { index -> CGRect? in
        let title = regions[index]
        guard title.sourceText.range(of: #"(?i)^table\s*\d"#, options: .regularExpression) != nil,
          let note = candidates.map({ regions[$0] }).filter({
            $0.bounds.maxY < title.bounds.minY && $0.bounds.minX >= title.bounds.minX - 12
              && $0.sourceText.range(of: #"(?i)^note(?:s)?[:.]"#, options: .regularExpression)
                != nil
          }).max(by: { $0.bounds.maxY < $1.bounds.maxY })
        else { return nil }
        return title.bounds.union(note.bounds)
      }
      let body = candidates.filter { index in
        let r = regions[index]
        let isHeading =
          r.sourceText.range(
            of: #"^\d+(?:\.\d+)*[.]?\s+\p{L}"#,
            options: .regularExpression) != nil || r.bold == true
        return r.bounds.midY > box.minY + box.height * 0.05
          && r.bounds.midY < box.maxY - box.height * 0.05
          && !((r.bounds.midY < box.minY + box.height * 0.12
            || r.bounds.midY > box.maxY - box.height * 0.12)
            && r.sourceText.count < 180 && repeated[normalized(r.sourceText)] != nil)
          && (isHeading || r.preferredFontSize >= bodyFont * 0.8)
          && r.sourceText.range(of: #"^\s*\d+\s*$"#, options: .regularExpression) == nil
          && !isCaption(r.sourceText)
          && !tableZones.contains(where: {
            $0.contains(CGPoint(x: r.bounds.midX, y: r.bounds.midY))
          })
          && (isHeading || (r.sourceText.count >= 4 && r.bounds.width >= r.preferredFontSize * 2))
      }
      return readingOrder(body, regions: regions)
    }
    func prose(_ r: PDFTranslationRegion) -> Bool {
      let text = r.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
      return r.bold != true && r.centered != true && text.count >= 4
        && text.contains(where: \.isLetter)
        && text.range(of: #"^\d+(?:\.\d+)*[.]?\s+\p{L}"#, options: .regularExpression) == nil
        && text.range(
          of:
            #"(?i)^(?:fig(?:ure)?\.?|table|references|bibliography|图|表|参考文献|\[\d+\]|\d+[.)])(?:\s|$)"#,
          options: .regularExpression) == nil
    }
    guard !pageBounds.isEmpty else { return result }
    let orders = pageBounds.indices.map { bodyOrder($0) }
    var boundaries: [(Int, Int)] = []
    for page in pageBounds.indices {
      let order = orders[page]
      for (end, start) in zip(order, order.dropFirst()) {
        let a = regions[end].bounds
        let b = regions[start].bounds
        let separateColumns = a.maxX <= b.minX
        let sameColumn =
          abs(a.minX - b.minX) <= regions[end].preferredFontSize * 1.5
          && b.maxY <= a.minY + 2
          && a.minY - b.maxY <= regions[end].preferredFontSize * 1.8
        if separateColumns || sameColumn { boundaries.append((end, start)) }
      }
      if page + 1 < pageBounds.count, let end = order.last, let start = orders[page + 1].first {
        boundaries.append((end, start))
      }
    }
    for (end, start) in boundaries {
      let a = regions[end]
      let b = regions[start]
      let tail = a.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
      let head = b.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
      let strippedTail = tail.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}"))
      let lowerStart = head.first?.isLowercase == true
      let technicalStart =
        head.range(of: #"^[A-Z][A-Za-z]*[0-9]+\b"#, options: .regularExpression) != nil
      let connectiveTail = [
        "and", "or", "the", "of", "to", "with", "in", "from", "by", "for", "as", "using",
      ]
      .contains(tail.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? "")
      let cjkStart =
        head.unicodeScalars.first.map {
          (0x3040...0x30FF).contains(Int($0.value)) || (0x3400...0x9FFF).contains(Int($0.value))
            || (0xAC00...0xD7AF).contains(Int($0.value))
        } ?? false
      let abbreviation =
        strippedTail.range(
          of: #"(?i)(?:\b(?:e\.g|i\.e|et al|vs|cf|dr|prof|fig|eq)|\b[A-Z])\.$"#,
          options: .regularExpression) != nil
      let openDelimiter = [("(", ")"), ("[", "]"), ("（", "）")].contains { opening, closing in
        tail.components(separatedBy: opening).count > tail.components(separatedBy: closing).count
      }
      guard prose(a), prose(b), a.kind == b.kind,
        tail.count + head.count >= 35,
        abs(a.preferredFontSize - b.preferredFontSize) <= max(0.75, a.preferredFontSize * 0.12),
        !(strippedTail.last.map { ".!?。！？".contains($0) } ?? true) || abbreviation,
        lowerStart || cjkStart || technicalStart || connectiveTail || openDelimiter,
        // Short fragments require a clear lexical continuation, not just matching geometry.
        min(tail.count, head.count) >= 12 || lowerStart || cjkStart,
        !head.hasPrefix("http"), !head.hasPrefix("doi:")
      else { continue }
      let group = (result[end].continuationGroup ?? [a.id]) + [b.id]
      let members = result.indices.filter { group.contains(result[$0].id) }
      guard members.reduce(0, { $0 + result[$1].sourceText.count }) <= 12_000 else { continue }
      for index in members {
        result[index].continuationGroup = group
        result[index].continuationVersion = 3
      }
    }
    return result
  }

  /// Recursive whitespace cuts infer columns from the actual text geometry.
  /// A spanning heading splits the page into horizontal bands before columns
  /// are inferred within each band. No fixed page midpoint or column count.
  static func readingOrder(_ indices: [Int], regions: [PDFTranslationRegion]) -> [Int] {
    guard indices.count > 1 else { return indices }
    func cut(vertical: Bool) -> ([Int], [Int])? {
      let sorted = indices.sorted {
        let a = regions[$0].bounds
        let b = regions[$1].bounds
        return vertical ? a.minX < b.minX : a.minY < b.minY
      }
      var edge = vertical ? regions[sorted[0]].bounds.maxX : regions[sorted[0]].bounds.maxY
      var best: (Int, CGFloat)?
      for offset in 1..<sorted.count {
        let box = regions[sorted[offset]].bounds
        let gap = (vertical ? box.minX : box.minY) - edge
        let threshold: CGFloat = vertical ? 4 : 2
        if gap > threshold, best == nil || gap > best!.1 { best = (offset, gap) }
        edge = max(edge, vertical ? box.maxX : box.maxY)
      }
      guard let best else { return nil }
      let low = Array(sorted.prefix(best.0))
      let high = Array(sorted.dropFirst(best.0))
      return vertical ? (low, high) : (high, low)
    }
    if let (first, second) = cut(vertical: true) ?? cut(vertical: false) {
      return readingOrder(first, regions: regions) + readingOrder(second, regions: regions)
    }
    return indices.sorted {
      let a = regions[$0].bounds
      let b = regions[$1].bounds
      if abs(a.maxY - b.maxY) > 2 { return a.maxY > b.maxY }
      if a.minX != b.minX { return a.minX < b.minX }
      return regions[$0].id < regions[$1].id
    }
  }

  static func writeTranslatedPDF(
    inputURL: URL,
    regions: [PDFTranslationRegion],
    translations: [String: String],
    outputURL: URL, automaticallySupplementOverflow: Bool = false
  ) throws -> PDFLayoutTranslationReport {
    guard let source = CGPDFDocument(inputURL as CFURL), source.numberOfPages > 0,
      let sourceDocument = PDFDocument(url: inputURL),
      sourceDocument.pageCount == source.numberOfPages
    else {
      throw NativeDocumentError.invalidFile("无法打开 PDF 图像内容。")
    }
    let identifiers = Set(regions.map(\.id))
    guard identifiers.count == regions.count else {
      throw NativeDocumentError.processing("PDF 翻译区域标识重复，已停止生成结果。")
    }
    let missing = regions.filter {
      translations[$0.id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }
    guard missing.isEmpty else {
      throw NativeDocumentError.provider("翻译服务缺少 \(missing.count) 个文字区域的译文。")
    }

    let byPage = Dictionary(grouping: regions, by: \.pageIndex)
    let output = PDFDocument()
    var overflowRegionIDs: [String] = []
    for pageIndex in 0..<source.numberOfPages {
      try Task.checkCancellation()
      guard let page = source.page(at: pageIndex + 1),
        let sourcePage = sourceDocument.page(at: pageIndex)
      else {
        throw NativeDocumentError.invalidFile("无法读取 PDF 的第 \(pageIndex + 1) 页。")
      }
      var mediaBox = page.getBoxRect(.mediaBox)
      guard mediaBox.width > 0, mediaBox.height > 0 else {
        throw NativeDocumentError.invalidFile("PDF 的第 \(pageIndex + 1) 页尺寸无效。")
      }
      let renderedPage = try autoreleasepool { () throws -> PDFPage in
        guard let backgroundPage = render(page: page, maximumDimension: 3_600),
          let backgroundImage = compressedBackground(backgroundPage.image)
        else {
          throw NativeDocumentError.processing("无法生成第 \(pageIndex + 1) 页背景。")
        }
        let pageData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pageData as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
          throw NativeDocumentError.processing("无法创建保留版式的 PDF 页面。")
        }
        context.beginPDFPage(nil)
        // A raster background prevents covered source glyphs from surviving in the text layer.
        // Undo the render transform so the original page coordinates and Rotate remain intact.
        context.saveGState()
        context.concatenate(backgroundPage.pageToImageTransform.inverted())
        context.draw(
          backgroundImage,
          in: CGRect(
            x: 0, y: 0, width: backgroundImage.width, height: backgroundImage.height))
        context.restoreGState()
        let sampler = PageBackgroundSampler(renderedPage: backgroundPage)
        let visibleBox = sourcePage.bounds(for: .cropBox).intersection(mediaBox)
        for region in byPage[pageIndex, default: []] {
          try Task.checkCancellation()
          if region.kind == .imageOCR,
            byPage[pageIndex, default: []].contains(where: {
              duplicatesNativeLine(region.sourceText, bounds: region.bounds, native: $0)
            })
          {
            continue
          }
          let text = layoutText(translations[region.id]!, for: region)
          if region.preserveOriginal == true
            || normalizedForComparison(text) == normalizedForComparison(region.sourceText)
          {
            drawSearchableOriginal(region.sourceText, in: region.bounds, context: context)
            continue
          }
          let background = sampler.color(around: region.bounds)
          if region.kind == .imageOCR, region.sourceText.count >= 12,
            region.sourceText.contains("-"), !region.sourceText.contains(where: \.isWhitespace),
            (0.8...1.25).contains(region.bounds.width / max(1, region.bounds.height))
          {
            // Long diagonal chart labels have square OCR boxes. Mask only the rotated
            // text strip, otherwise its bounding square erases adjacent chart labels.
            let sourceLine = CTLineCreateWithAttributedString(
              NSAttributedString(
                string: region.sourceText, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
            let advance = CTLineGetTypographicBounds(sourceLine, nil, nil, nil)
            let diagonal = hypot(region.bounds.width, region.bounds.height)
            let size = min(region.preferredFontSize, max(5, diagonal * 12 / max(1, advance)))
            let strip = CGRect(
              x: -diagonal / 2, y: -size * 0.65,
              width: diagonal, height: size * 1.3)
            let fits = drawFittedText(
              text, in: strip, preferredFontSize: size,
              background: background, context: context, estimatedFont: true, measureOnly: true)
            if fits {
              context.saveGState()
              context.translateBy(x: region.bounds.midX, y: region.bounds.midY)
              context.rotate(by: atan2(region.bounds.height, region.bounds.width))
              context.setFillColor(background.cgColor)
              context.fill(strip)
              _ = drawFittedText(
                text, in: strip, preferredFontSize: size,
                background: background, context: context, estimatedFont: true)
              context.restoreGState()
            } else {
              overflowRegionIDs.append(region.id)
              drawSearchableOriginal(region.sourceText, in: region.bounds, context: context)
            }
            continue
          }
          let cover = region.bounds.insetBy(dx: -0.8, dy: -0.6).intersection(visibleBox)
          context.setFillColor(background.cgColor)
          context.fill(cover)
          var target = region.bounds.insetBy(dx: -0.4, dy: -0.2).intersection(visibleBox)
          if region.kind == .imageOCR {
            // OCR boxes describe ink, not the complete line box. Allow a small inset
            // only when it stays clear of other text regions.
            let candidates = [
              region.bounds.insetBy(dx: -1.5, dy: -0.8),
              CGRect(
                x: region.bounds.minX, y: region.bounds.minY - 1.6,
                width: region.bounds.width, height: region.bounds.height + 1.6),
            ]
            for candidate in candidates {
              let padded = candidate.intersection(visibleBox)
              let collision = byPage[pageIndex, default: []].contains { other in
                guard other.id != region.id, other.preserveOriginal != true else { return false }
                let before = other.bounds.intersection(region.bounds)
                let after = other.bounds.intersection(padded)
                let oldArea = before.isNull ? 0 : before.width * before.height
                let newArea = after.isNull ? 0 : after.width * after.height
                return newArea > oldArea + 0.01
              }
              if !collision {
                target = padded
                break
              }
            }
          }
          let vertical = isVerticalLabel(region)
          context.saveGState()
          if vertical {
            context.translateBy(x: target.maxX, y: target.minY)
            context.rotate(by: .pi / 2)
          }
          let fitted = drawFittedText(
            text,
            in: vertical ? CGRect(x: 0, y: 0, width: target.height, height: target.width) : target,
            preferredFontSize: vertical
              ? max(5, region.bounds.width * 0.72) : region.preferredFontSize,
            background: background, context: context,
            bold: region.bold == true, centered: shouldCenter(region),
            textColor: region.textColor, estimatedFont: region.kind == .imageOCR)
          context.restoreGState()
          if !fitted {
            overflowRegionIDs.append(region.id)
            if automaticallySupplementOverflow {
              // Restore the original pixels and searchable text; the complete translation
              // is carried on an automatically appended note page rather than discarded.
              context.saveGState()
              context.clip(to: cover)
              context.concatenate(backgroundPage.pageToImageTransform.inverted())
              context.draw(
                backgroundImage,
                in: CGRect(
                  x: 0, y: 0, width: backgroundImage.width, height: backgroundImage.height))
              context.restoreGState()
              drawSearchableOriginal(region.sourceText, in: region.bounds, context: context)
            }
          }
        }
        context.endPDFPage()
        context.closePDF()
        guard let rendered = PDFDocument(data: pageData as Data),
          let resultPage = rendered.page(at: 0)?.copy() as? PDFPage
        else {
          throw NativeDocumentError.processing("无法组装保留版式的第 \(pageIndex + 1) 页。")
        }
        for box: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
          resultPage.setBounds(sourcePage.bounds(for: box), for: box)
        }
        resultPage.rotation = sourcePage.rotation
        return resultPage
      }
      output.insert(renderedPage, at: output.pageCount)
    }
    var report = PDFLayoutTranslationReport(
      pageCount: output.pageCount,
      nativeRegionCount: regions.count { $0.kind == .nativeText },
      imageOCRRegionCount: regions.count { $0.kind == .imageOCR },
      overflowRegionIDs: overflowRegionIDs)
    guard overflowRegionIDs.isEmpty || automaticallySupplementOverflow else { return report }
    // Copy annotations after all destination pages exist, including internal navigation links.
    for pageIndex in 0..<sourceDocument.pageCount {
      try Task.checkCancellation()
      guard let original = sourceDocument.page(at: pageIndex),
        let translated = output.page(at: pageIndex)
      else { throw NativeDocumentError.processing("无法保留 PDF 页面批注。") }
      for annotation in original.annotations {
        guard let copy = annotation.copy() as? PDFAnnotation else {
          throw NativeDocumentError.processing("无法保留 PDF 页面批注。")
        }
        if let border = annotation.border {
          copy.border = border.copy() as? PDFBorder
        } else if annotation.type == "Link" {
          // An omitted PDF link border means a 1 pt solid line. PDFKit rewrites nil as 0 pt.
          let defaultBorder = PDFBorder()
          defaultBorder.lineWidth = 1
          copy.border = defaultBorder
        }
        remapDestination(of: copy, from: annotation, sourceDocument: sourceDocument) {
          output.page(at: $0)
        }
        translated.addAnnotation(copy)
      }
    }
    if !overflowRegionIDs.isEmpty {
      let overflow = Set(overflowRegionIDs)
      let notes = regions.filter { overflow.contains($0.id) }
      let notesURL = outputURL.deletingLastPathComponent()
        .appendingPathComponent(".translation-notes-\(UUID().uuidString).pdf")
      defer { try? FileManager.default.removeItem(at: notesURL) }
      try writeSupplementPDF(notes, translations: translations, to: notesURL)
      guard let appendix = PDFDocument(url: notesURL), appendix.pageCount > 0 else {
        throw NativeDocumentError.processing("无法生成补充译文页面。")
      }
      for index in 0..<appendix.pageCount {
        guard let page = appendix.page(at: index)?.copy() as? PDFPage else {
          throw NativeDocumentError.processing("无法读取补充译文页面。")
        }
        output.insert(page, at: output.pageCount)
      }
      for (index, region) in notes.enumerated() {
        let annotation = PDFAnnotation(bounds: region.bounds, forType: .square, withProperties: nil)
        annotation.color = NSColor.systemOrange.withAlphaComponent(0.65)
        annotation.contents = "补充译文 [\(index + 1)]，见文末。\n\(translations[region.id]!)"
        let border = PDFBorder()
        border.lineWidth = 0.5
        annotation.border = border
        output.page(at: region.pageIndex)?.addAnnotation(annotation)
      }
      output.documentAttributes = [PDFDocumentAttribute.subjectAttribute: supplementMarker]
      report = PDFLayoutTranslationReport(
        pageCount: output.pageCount, nativeRegionCount: report.nativeRegionCount,
        imageOCRRegionCount: report.imageOCRRegionCount, overflowRegionIDs: [],
        supplementedRegionIDs: overflowRegionIDs)
    }
    guard output.pageCount >= source.numberOfPages, output.write(to: outputURL) else {
      throw NativeDocumentError.processing("无法写入保留原版式的译文 PDF。")
    }
    return report
  }

  private static func remapDestination(
    of copy: PDFAnnotation, from original: PDFAnnotation, sourceDocument: PDFDocument,
    transformPoint: (CGPoint, Int) -> CGPoint = { point, _ in point },
    targetPage: (Int) -> PDFPage?
  ) {
    guard let action = original.action as? PDFActionGoTo else { return }
    guard let sourcePage = action.destination.page else {
      // Some publisher PDFs reference names absent from their destination tree.
      // Retain the annotation appearance without serializing an invalid page reference.
      copy.removeValue(forAnnotationKey: .destination)
      copy.action = nil
      return
    }
    let index = sourceDocument.index(for: sourcePage)
    guard index != NSNotFound, let target = targetPage(index) else { return }
    let destination = PDFDestination(
      page: target, at: transformPoint(action.destination.point, index))
    destination.zoom = action.destination.zoom
    // A copied /Dest can still point into the old document even after assigning /A.
    copy.removeValue(forAnnotationKey: .destination)
    copy.action = PDFActionGoTo(destination: destination)
  }

  private static func compressedBackground(_ image: CGImage) -> CGImage? {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: 0.94] as CFDictionary)
    guard CGImageDestinationFinalize(destination),
      let provider = CGDataProvider(data: data as CFData)
    else { return nil }
    return CGImage(
      jpegDataProviderSource: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }

  private static func nativeRegions(
    page: PDFPage, pageIndex: Int, pageBounds: CGRect
  ) -> [PDFTranslationRegion] {
    guard let selection = page.selection(for: pageBounds) else { return [] }
    let lines = selection.selectionsByLine().compactMap { line -> NativeLine? in
      let text =
        line.string?.replacingOccurrences(of: "\u{FFFC}", with: "")
        .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
      let bounds = line.bounds(for: page).intersection(pageBounds)
      guard !text.isEmpty, bounds.width >= 2, bounds.height >= 2 else { return nil }
      var fontSize = max(5, min(24, bounds.height * 0.72))
      var bold = false
      var textColor: [Double]?
      if let attributed = line.attributedString, attributed.length > 0 {
        var dominantFont: NSFont?
        var dominantLength = 0
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) {
          value, range, _ in
          if let font = value as? NSFont, range.length > dominantLength {
            dominantFont = font
            dominantLength = range.length
          }
        }
        if let font = dominantFont {
          fontSize = font.pointSize
          bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        }
        if let color =
          (attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
          .usingColorSpace(.deviceRGB)
        {
          textColor = [
            Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent),
          ]
        }
      }
      // Rotated publication stamps have enormous axis-aligned boxes that overlap body text.
      // Keep their appearance; never use those boxes as translation masks or paragraph lines.
      let publicationStamp = ["ARTICLE IN PRESS", "ACCEPTED MANUSCRIPT"].contains(text.uppercased())
      let preserveOriginal = publicationStamp || bounds.height > fontSize * 2.5
      return NativeLine(
        text: text, bounds: bounds, fontSize: fontSize, bold: bold, textColor: textColor,
        preserveOriginal: preserveOriginal)
    }
    guard !lines.isEmpty else { return [] }

    // PDFKit may split one author line into separate selections at each superscript.
    // Rejoin adjacent runs before grouping paragraphs, without crossing column gutters.
    var joinedLines: [NativeLine] = []
    for line in lines.filter({ !$0.preserveOriginal }) {
      if let previous = joinedLines.last,
        abs(previous.bounds.minY - line.bounds.minY) <= min(
          previous.bounds.height, line.bounds.height) * 0.35,
        line.bounds.minX >= previous.bounds.maxX - 1,
        line.bounds.minX - previous.bounds.maxX <= max(previous.fontSize, line.fontSize) * 0.65
      {
        joinedLines[joinedLines.count - 1] = NativeLine(
          text: previous.text + " " + line.text, bounds: previous.bounds.union(line.bounds),
          fontSize: max(previous.fontSize, line.fontSize), bold: previous.bold,
          textColor: previous.textColor)
      } else {
        joinedLines.append(line)
      }
    }
    var groups: [[NativeLine]] = []
    for line in joinedLines {
      if let last = groups.last?.last, shouldMerge(last, line) {
        groups[groups.count - 1].append(line)
      } else {
        groups.append([line])
      }
    }
    groups.append(contentsOf: lines.filter(\.preserveOriginal).map { [$0] })
    return groups.enumerated().map { index, group in
      let bounds = group.dropFirst().reduce(group[0].bounds) { $0.union($1.bounds) }
      let fontSize = group.map(\.fontSize).sorted()[group.count / 2]
      return PDFTranslationRegion(
        id: regionID(pageIndex: pageIndex, kind: .nativeText, number: index + 1),
        pageIndex: pageIndex,
        kind: .nativeText,
        bounds: bounds,
        sourceText: group.map(\.text).joined(separator: "\n"),
        preferredFontSize: fontSize, bold: group[0].bold,
        centered: (group.map(\.text).joined().count <= 200 || fontSize >= 16)
          && abs(bounds.midX - pageBounds.midX) < pageBounds.width * 0.08
          && group.allSatisfy { abs($0.bounds.midX - bounds.midX) < fontSize },
        textColor: group[0].textColor, preserveOriginal: group[0].preserveOriginal)
    }
  }

  private static func shouldMerge(_ first: NativeLine, _ second: NativeLine) -> Bool {
    let horizontalOverlap = max(
      0, min(first.bounds.maxX, second.bounds.maxX) - max(first.bounds.minX, second.bounds.minX))
    let narrowerWidth = min(first.bounds.width, second.bounds.width)
    let overlap = narrowerWidth > 0 ? horizontalOverlap / narrowerWidth : 0
    let verticalGap = max(
      0,
      max(first.bounds.minY, second.bounds.minY) - min(first.bounds.maxY, second.bounds.maxY))
    let comparableFont = abs(first.fontSize - second.fontSize) <= max(0.75, first.fontSize * 0.12)
    // Double-spaced manuscripts leave a full font-size gap between successive lines.
    // A short final line or a new indent still starts a new paragraph.
    let continuesParagraph =
      first.bounds.maxX >= second.bounds.maxX - first.fontSize * 2
      && second.bounds.minX <= first.bounds.minX + first.fontSize * 0.8
    let readsDownward = second.bounds.midY < first.bounds.midY
    return overlap >= 0.45 && verticalGap <= max(3, min(first.fontSize, second.fontSize) * 1.3)
      && comparableFont && first.bold == second.bold && continuesParagraph && readsDownward
  }

  private static func regionID(
    pageIndex: Int, kind: PDFTranslationRegion.Kind, number: Int
  ) -> String {
    String(
      format: "p%04d-%@%04d", pageIndex + 1, kind == .nativeText ? "t" : "i", number)
  }

  private static func overlapRatio(_ first: CGRect, _ second: CGRect) -> CGFloat {
    let intersection = first.intersection(second)
    guard !intersection.isNull else { return 0 }
    let denominator = min(first.width * first.height, second.width * second.height)
    return denominator > 0 ? intersection.width * intersection.height / denominator : 0
  }

  private static func normalizedForDeduplication(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .filter { !$0.isWhitespace && !$0.isPunctuation }
  }

  private static func recognizeText(_ image: CGImage, languages: [String]) throws
    -> [OCRObservation]
  {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = languages
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      return OCRObservation(
        text: candidate.string, normalizedBounds: observation.boundingBox,
        confidence: candidate.confidence)
    }
  }

  private static func render(page: CGPDFPage, maximumDimension: CGFloat) -> RenderedPage? {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let normalizedRotation = ((page.rotationAngle % 360) + 360) % 360
    let isQuarterTurn = normalizedRotation == 90 || normalizedRotation == 270
    let drawingSize = CGSize(
      width: isQuarterTurn ? box.height : box.width,
      height: isQuarterTurn ? box.width : box.height)
    let scale = min(maximumDimension / max(drawingSize.width, drawingSize.height), 4)
    let width = max(1, Int((drawingSize.width * scale).rounded(.up)))
    let height = max(1, Int((drawingSize.height * scale).rounded(.up)))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let drawingRect = CGRect(origin: .zero, size: drawingSize)
    let pageToDrawingTransform = page.getDrawingTransform(
      .mediaBox, rect: drawingRect, rotate: 0, preserveAspectRatio: true)
    let pageToImageTransform = pageToDrawingTransform.concatenating(
      CGAffineTransform(scaleX: scale, y: scale))
    context.concatenate(pageToImageTransform)
    context.drawPDFPage(page)
    guard let image = context.makeImage() else { return nil }
    return RenderedPage(image: image, pageToImageTransform: pageToImageTransform)
  }

  private static func duplicatesNativeLine(
    _ text: String, bounds: CGRect, native: PDFTranslationRegion
  ) -> Bool {
    guard native.kind == .nativeText, native.preserveOriginal != true,
      overlapRatio(bounds, native.bounds) >= 0.65
    else { return false }
    func words(_ text: String) -> Set<String> {
      Set(
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter {
          !$0.isEmpty
        })
    }
    let recognized = words(text)
    // Ignore one-character chart labels and tolerate a single OCR substitution such as µm -> pm.
    return recognized.count >= 5
      && Double(recognized.intersection(words(native.sourceText)).count)
        / Double(recognized.count) >= 0.85
  }

  static func shouldCenter(_ region: PDFTranslationRegion) -> Bool {
    // Full-width justified body lines share a center without being centered paragraphs.
    // Apply this to cached regions too, so rebuilding an existing translation repairs alignment.
    region.centered == true
      && (region.sourceText.count <= 200 || region.preferredFontSize >= 16)
  }

  static func isVerticalLabel(_ region: PDFTranslationRegion) -> Bool {
    region.kind == .imageOCR && region.bounds.height > region.bounds.width * 2.5
      && region.sourceText.count > 3
      && region.sourceText.contains(where: { $0.isASCII && $0.isLetter })
  }

  static func layoutText(_ translation: String, for region: PDFTranslationRegion) -> String {
    var text = translation.trimmingCharacters(in: .whitespacesAndNewlines)
    if region.kind == .nativeText && !region.sourceText.contains("\n\n")
      && region.sourceText.range(
        of: #"(?m)^\s*(?:[•*–-]|\(?[0-9ivx]+[.)])\s"#, options: .regularExpression) == nil
    {
      text = text.replacingOccurrences(
        of: #"(?<=\p{Han})\n(?=\p{Han})"#, with: "", options: .regularExpression
      )
      .replacingOccurrences(of: "\n", with: " ")
    }
    if region.kind == .imageOCR {
      // Keep the compact Latin punctuation used in gene lists and chart units.
      text = text.replacingOccurrences(of: "、", with: ",")
        .replacingOccurrences(of: "，", with: ",")
        .replacingOccurrences(of: "：", with: ":")
        .replacingOccurrences(of: "。", with: ".")
    }
    return text
  }

  private static func normalizedForComparison(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping
      .replacingOccurrences(of: "、", with: ",")
      .replacingOccurrences(of: "。", with: ".")
      .filter { !$0.isWhitespace }
  }

  private static func writeSupplementPDF(
    _ regions: [PDFTranslationRegion], translations: [String: String], to url: URL
  ) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 1206, height: 842)
    guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
      throw NativeDocumentError.processing("无法创建补充译文。")
    }
    defer { context.closePDF() }
    let columns = [
      CGRect(x: 48, y: 48, width: 539, height: 708),
      CGRect(x: 619, y: 48, width: 539, height: 708),
    ]
    for (number, region) in regions.enumerated() {
      let texts = [region.sourceText, translations[region.id]!]
      let attributed = texts.map { text in
        NSAttributedString(
          string: text,
          attributes: [
            .font: NSFont(name: "PingFangSC-Regular", size: 11.5)!,
            .foregroundColor: NSColor.black,
          ])
      }
      let framesetters = attributed.map { CTFramesetterCreateWithAttributedString($0) }
      var offsets = [0, 0]
      repeat {
        try Task.checkCancellation()
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(mediaBox)
        let title = "补充译文 [\(number + 1)] · 原文第 \(region.pageIndex + 1) 页"
        let heading = CTLineCreateWithAttributedString(
          NSAttributedString(
            string: title, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold)]))
        context.textPosition = CGPoint(x: 48, y: 802)
        CTLineDraw(heading, context)
        for side in 0..<2 {
          let label = CTLineCreateWithAttributedString(
            NSAttributedString(
              string: side == 0 ? "原文" : "译文",
              attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]))
          context.textPosition = CGPoint(x: columns[side].minX, y: 776)
          CTLineDraw(label, context)
          guard offsets[side] < attributed[side].length else { continue }
          let frame = CTFramesetterCreateFrame(
            framesetters[side], CFRange(location: offsets[side], length: 0),
            CGPath(rect: columns[side], transform: nil), nil)
          let visible = CTFrameGetVisibleStringRange(frame)
          guard visible.length > 0 else {
            throw NativeDocumentError.processing("补充译文排版失败。")
          }
          CTFrameDraw(frame, context)
          offsets[side] += visible.length
        }
        context.endPDFPage()
      } while offsets[0] < attributed[0].length || offsets[1] < attributed[1].length
    }
  }

  private static func drawSearchableOriginal(_ text: String, in bounds: CGRect, context: CGContext)
  {
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: text.replacingOccurrences(of: "\n", with: " "),
        attributes: [.font: NSFont.systemFont(ofSize: 10)]))
    let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    guard ink.width > 0, ink.height > 0 else { return }
    context.saveGState()
    context.translateBy(x: bounds.minX, y: bounds.minY)
    context.scaleBy(x: bounds.width / ink.width, y: bounds.height / ink.height)
    context.textPosition = CGPoint(x: -ink.minX, y: -ink.minY)
    context.setTextDrawingMode(.invisible)
    CTLineDraw(line, context)
    context.restoreGState()
  }

  private static func drawFittedText(
    _ text: String,
    in bounds: CGRect,
    preferredFontSize: CGFloat,
    background: NSColor,
    context: CGContext, bold: Bool = false, centered: Bool = false, textColor: [Double]? = nil,
    estimatedFont: Bool = false, measureOnly: Bool = false
  ) -> Bool {
    guard bounds.width > 1, bounds.height > 1 else { return false }
    let luminance =
      0.2126 * background.redComponent + 0.7152 * background.greenComponent
      + 0.0722 * background.blueComponent
    var foreground = luminance < 0.38 ? NSColor.white : NSColor(calibratedWhite: 0.08, alpha: 1)
    if let textColor, textColor.count == 3,
      textColor.allSatisfy({ $0.isFinite && (0...1).contains($0) })
    {
      foreground = NSColor(red: textColor[0], green: textColor[1], blue: textColor[2], alpha: 1)
    }
    // Small original labels must not be enlarged beyond the space the publisher allocated.
    let preferred = min(30, max(5, preferredFontSize))
    let minimum = min(
      preferred,
      estimatedFont
        ? 5
        : max(
          preferred < minimumTranslationFontSize ? 5 : minimumTranslationFontSize,
          preferred * minimumTranslationFontScale))
    var fontSize = preferred
    while fontSize >= minimum {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byWordWrapping
      paragraph.alignment = centered ? .center : .left
      paragraph.lineSpacing = 0
      let attributed = NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize),
          .foregroundColor: foreground,
          .paragraphStyle: paragraph,
        ])
      if !text.contains("\n") {
        let line = CTLineCreateWithAttributedString(attributed)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if !ink.isEmpty, ink.width <= bounds.width, ink.height <= bounds.height {
          if measureOnly { return true }
          context.saveGState()
          context.textPosition = CGPoint(
            x: centered ? bounds.midX - ink.midX : bounds.minX - ink.minX,
            y: bounds.maxY - ink.maxY)
          CTLineDraw(line, context)
          context.restoreGState()
          return true
        }
      }
      let framesetter = CTFramesetterCreateWithAttributedString(attributed)
      // PDF selection bounds describe glyph ink, not a paragraph's typographic line box.
      // Measure the rendered ink before positioning it, so CJK ascenders do not force tiny type.
      let layoutBounds = CGRect(
        x: 0, y: 0, width: bounds.width,
        height: bounds.height + fontSize * 3)
      let path = CGPath(rect: layoutBounds, transform: nil)
      let frame = CTFramesetterCreateFrame(
        framesetter, CFRange(location: 0, length: attributed.length), path, nil)
      let visible = CTFrameGetVisibleStringRange(frame)
      let lines = CTFrameGetLines(frame) as! [CTLine]
      var origins = Array(repeating: CGPoint.zero, count: lines.count)
      CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
      var ink = CGRect.null
      for (index, line) in lines.enumerated() {
        let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        if !lineBounds.isEmpty {
          ink = ink.union(lineBounds.offsetBy(dx: origins[index].x, dy: origins[index].y))
        }
      }
      if visible.location == 0, visible.length >= attributed.length,
        !ink.isNull, ink.width <= bounds.width, ink.height <= bounds.height
      {
        if measureOnly { return true }
        context.saveGState()
        context.translateBy(
          x: centered ? bounds.midX - ink.midX : bounds.minX - ink.minX,
          y: bounds.maxY - ink.maxY)
        CTFrameDraw(frame, context)
        context.restoreGState()
        return true
      }
      if fontSize <= minimum { break }
      fontSize = max(minimum, fontSize - 0.5)
    }
    return false
  }
}
