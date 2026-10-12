import PDFKit

extension PDFLayoutTranslation {
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

  static func remapDestination(
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
