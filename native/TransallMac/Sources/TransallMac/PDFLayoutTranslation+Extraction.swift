import PDFKit
import Vision

extension PDFLayoutTranslation {
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

  static func render(page: CGPDFPage, maximumDimension: CGFloat) -> RenderedPage? {
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

  static func duplicatesNativeLine(
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
}
