import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Vision

struct PDFTranslationRegion: Equatable, Sendable {
  enum Kind: String, Sendable {
    case nativeText
    case imageOCR
  }

  let id: String
  let pageIndex: Int
  let kind: Kind
  let bounds: CGRect
  let sourceText: String
  let preferredFontSize: CGFloat
}

struct PDFLayoutTranslationReport: Equatable, Sendable {
  let pageCount: Int
  let nativeRegionCount: Int
  let imageOCRRegionCount: Int
  let overflowRegionIDs: [String]
}

enum PDFLayoutTranslation {
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
          let overlap = overlapRatio(bounds, $0.bounds)
          let nativeText = normalizedForDeduplication($0.sourceText)
          return overlap >= 0.45 && nativeText.contains(normalizedText)
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
    return result
  }

  static func writeTranslatedPDF(
    inputURL: URL,
    regions: [PDFTranslationRegion],
    translations: [String: String],
    outputURL: URL
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
          let background = sampler.color(around: region.bounds)
          let cover = region.bounds.insetBy(dx: -0.8, dy: -0.6).intersection(visibleBox)
          context.setFillColor(background.cgColor)
          context.fill(cover)
          let text = translations[region.id]!.trimmingCharacters(in: .whitespacesAndNewlines)
          if !drawFittedText(
            text, in: region.bounds.insetBy(dx: -0.4, dy: -0.2).intersection(visibleBox),
            preferredFontSize: region.preferredFontSize, background: background, context: context)
          {
            overflowRegionIDs.append(region.id)
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
    let report = PDFLayoutTranslationReport(
      pageCount: output.pageCount,
      nativeRegionCount: regions.count { $0.kind == .nativeText },
      imageOCRRegionCount: regions.count { $0.kind == .imageOCR },
      overflowRegionIDs: overflowRegionIDs)
    guard overflowRegionIDs.isEmpty else { return report }
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
        if let action = annotation.action as? PDFActionGoTo,
          let targetPage = action.destination.page
        {
          let targetIndex = sourceDocument.index(for: targetPage)
          if let newTarget = output.page(at: targetIndex) {
            let destination = PDFDestination(page: newTarget, at: action.destination.point)
            destination.zoom = action.destination.zoom
            copy.action = PDFActionGoTo(destination: destination)
          }
        }
        translated.addAnnotation(copy)
      }
    }
    guard output.pageCount == source.numberOfPages, output.write(to: outputURL) else {
      throw NativeDocumentError.processing("无法写入保留原版式的译文 PDF。")
    }
    return report
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
        line.string?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
      let bounds = line.bounds(for: page).intersection(pageBounds)
      guard !text.isEmpty, bounds.width >= 2, bounds.height >= 2 else { return nil }
      var fontSize = max(5, min(24, bounds.height * 0.72))
      if let attributed = line.attributedString, attributed.length > 0,
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
      {
        fontSize = font.pointSize
      }
      return NativeLine(text: text, bounds: bounds, fontSize: fontSize)
    }
    guard !lines.isEmpty else { return [] }

    var groups: [[NativeLine]] = []
    for line in lines {
      if let last = groups.last?.last, shouldMerge(last, line) {
        groups[groups.count - 1].append(line)
      } else {
        groups.append([line])
      }
    }
    return groups.enumerated().map { index, group in
      let bounds = group.dropFirst().reduce(group[0].bounds) { $0.union($1.bounds) }
      let fontSize = group.map(\.fontSize).sorted()[group.count / 2]
      return PDFTranslationRegion(
        id: regionID(pageIndex: pageIndex, kind: .nativeText, number: index + 1),
        pageIndex: pageIndex,
        kind: .nativeText,
        bounds: bounds,
        sourceText: group.map(\.text).joined(separator: "\n"),
        preferredFontSize: fontSize)
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
    let comparableFont = abs(first.fontSize - second.fontSize) <= max(2, first.fontSize * 0.25)
    return overlap >= 0.45 && verticalGap <= max(7, max(first.bounds.height, second.bounds.height))
      && comparableFont
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

  private static func drawFittedText(
    _ text: String,
    in bounds: CGRect,
    preferredFontSize: CGFloat,
    background: NSColor,
    context: CGContext
  ) -> Bool {
    guard bounds.width > 1, bounds.height > 1 else { return false }
    let luminance =
      0.2126 * background.redComponent + 0.7152 * background.greenComponent
      + 0.0722 * background.blueComponent
    let foreground = luminance < 0.38 ? NSColor.white : NSColor(calibratedWhite: 0.08, alpha: 1)
    let preferred = min(30, max(minimumTranslationFontSize, preferredFontSize))
    let minimum = max(minimumTranslationFontSize, preferred * minimumTranslationFontScale)
    var fontSize = preferred
    while fontSize >= minimum {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byWordWrapping
      paragraph.alignment = .left
      paragraph.lineSpacing = 0
      let attributed = NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont(name: "PingFangSC-Regular", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize),
          .foregroundColor: foreground,
          .paragraphStyle: paragraph,
        ])
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
        context.saveGState()
        context.translateBy(x: bounds.minX - ink.minX, y: bounds.maxY - ink.maxY)
        CTFrameDraw(frame, context)
        context.restoreGState()
        return true
      }
      fontSize -= 0.5
    }
    return false
  }
}
