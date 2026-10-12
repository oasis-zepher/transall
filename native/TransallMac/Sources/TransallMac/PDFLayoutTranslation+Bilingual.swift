import PDFKit

extension PDFLayoutTranslation {
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
}
