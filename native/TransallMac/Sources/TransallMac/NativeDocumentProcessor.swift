import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import Vision

enum NativeDocumentError: LocalizedError {
  case invalidFile(String)
  case invalidOption(String)
  case processing(String)
  case provider(String)

  var errorDescription: String? {
    switch self {
    case .invalidFile(let message), .invalidOption(let message), .processing(let message),
      .provider(let message):
      message
    }
  }

  var code: String {
    switch self {
    case .invalidFile: "invalid_file"
    case .invalidOption: "invalid_option"
    case .processing: "native_processing_failed"
    case .provider: "translation_provider_failed"
    }
  }

  var recoverySuggestion: String {
    switch self {
    case .invalidFile: "确认文件没有损坏，并与所选输入格式一致。"
    case .invalidOption: "修改任务参数后重新运行。"
    case .processing: "检查输入文件后重试；问题持续时可保留日志用于反馈。"
    case .provider: "检查网络、API Key、服务余额和服务商状态后重试。"
    }
  }
}

enum PageSelectionParser {
  static func indexes(_ specification: String, pageCount: Int) throws -> [Int] {
    let text = specification.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    var result: [Int] = []
    for rawPart in text.split(separator: ",", omittingEmptySubsequences: false) {
      let part = rawPart.trimmingCharacters(in: .whitespaces)
      guard !part.isEmpty else {
        throw NativeDocumentError.invalidOption("页码格式无效：请使用 2,4-6 这样的格式。")
      }
      let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
      if bounds.count == 1, let page = Int(bounds[0]) {
        try append(page, pageCount: pageCount, to: &result)
      } else if bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]),
        first <= last
      {
        for page in first...last {
          try append(page, pageCount: pageCount, to: &result)
        }
      } else {
        throw NativeDocumentError.invalidOption("页码格式无效：\(part)。")
      }
    }
    return result
  }

  private static func append(_ page: Int, pageCount: Int, to result: inout [Int]) throws {
    guard page >= 1, page <= pageCount else {
      throw NativeDocumentError.invalidOption("页码 \(page) 超出范围（共 \(pageCount) 页）。")
    }
    result.append(page - 1)
  }
}

enum NativeDocumentProcessor {
  struct Result: Sendable {
    let outputURL: URL
    let logs: [String]
  }

  private struct OCRLine {
    let text: String
    let box: CGRect
  }

  static func process(
    route: RouteDefinition,
    inputs: [URL],
    options: JobOptions,
    outputURL: URL,
    apiKey: String?
  ) async throws -> Result {
    try Task.checkCancellation()
    guard !inputs.isEmpty else {
      throw NativeDocumentError.invalidFile("没有可处理的输入文件。")
    }
    switch route.kind {
    case "pdf_edit":
      try editPDF(inputs: inputs, options: options, outputURL: outputURL)
      return Result(outputURL: outputURL, logs: ["PDF 已使用 PDFKit 处理。"])
    case "image_to_pdf":
      try imagesToPDF(inputs: inputs, outputURL: outputURL)
      return Result(outputURL: outputURL, logs: ["图片已按文件顺序写入 PDF。"])
    case "text_to_pdf":
      try textFilesToPDF(inputs: inputs, source: route.source, outputURL: outputURL)
      return Result(outputURL: outputURL, logs: ["文本已使用 Core Text 排版。"])
    case "ocr":
      try await performOCR(inputs: inputs, options: options, outputURL: outputURL)
      return Result(outputURL: outputURL, logs: ["文字识别在本机使用 Apple Vision 完成。"])
    case "extract_markdown":
      try await extractMarkdown(inputs: inputs, options: options, outputURL: outputURL)
      return Result(outputURL: outputURL, logs: ["文字已提取为 Markdown。"])
    case "pdf_translate":
      guard ["deepseek", "openai"].contains(options.provider) else {
        throw NativeDocumentError.invalidOption("翻译服务无效，请重新选择 DeepSeek 或 OpenAI。")
      }
      guard options.glossary.count <= TranslationService.maximumGlossaryCharacters else {
        throw NativeDocumentError.invalidOption(
          "术语表不能超过 \(TranslationService.maximumGlossaryCharacters) 个字符。")
      }
      guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw NativeDocumentError.provider("所选翻译服务尚未配置 API Key。")
      }
      try await translatePDF(
        input: inputs[0], options: options, outputURL: outputURL, apiKey: apiKey)
      return Result(
        outputURL: outputURL,
        logs: ["文档文字已发送给 \(options.provider == "openai" ? "OpenAI" : "DeepSeek") 并生成译文 PDF。"])
    default:
      throw NativeDocumentError.processing("此转换路径尚未由原生引擎实现。")
    }
  }

  static func makePreviews(pdfURL: URL, directory: URL, limit: Int = 8) throws -> [URL] {
    guard let document = CGPDFDocument(pdfURL as CFURL) else {
      throw NativeDocumentError.invalidFile("无法打开 PDF 结果以生成预览。")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var urls: [URL] = []
    let pageCount = min(document.numberOfPages, limit)
    guard pageCount > 0 else { return [] }
    for pageNumber in 1...pageCount {
      try Task.checkCancellation()
      guard let page = document.page(at: pageNumber),
        let image = render(page: page, maximumDimension: 1100)
      else {
        throw NativeDocumentError.processing("无法渲染第 \(pageNumber) 页预览。")
      }
      let url = directory.appendingPathComponent("page-\(pageNumber).png")
      guard
        let destination = CGImageDestinationCreateWithURL(
          url as CFURL, "public.png" as CFString, 1, nil)
      else {
        throw NativeDocumentError.processing("无法创建第 \(pageNumber) 页预览文件。")
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        throw NativeDocumentError.processing("无法写入第 \(pageNumber) 页预览文件。")
      }
      urls.append(url)
    }
    return urls
  }

  static func previewPageCount(pdfURL: URL, limit: Int = 8) throws -> Int {
    guard let document = CGPDFDocument(pdfURL as CFURL) else {
      throw NativeDocumentError.invalidFile("无法打开 PDF 结果以生成预览。")
    }
    return min(document.numberOfPages, max(0, limit))
  }

  static func isReadableImage(_ url: URL) -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
    return CGImageSourceGetCount(source) > 0
      && CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
  }

  private static func editPDF(inputs: [URL], options: JobOptions, outputURL: URL) throws {
    guard !inputs.isEmpty else { throw NativeDocumentError.invalidFile("没有可处理的 PDF。") }
    let document = PDFDocument()
    for input in inputs {
      try Task.checkCancellation()
      guard let source = PDFDocument(url: input) else {
        throw NativeDocumentError.invalidFile("无法打开 \(input.lastPathComponent)。")
      }
      for index in 0..<source.pageCount {
        guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
        document.insert(page, at: document.pageCount)
      }
    }
    guard document.pageCount > 0 else { throw NativeDocumentError.invalidFile("PDF 没有可用页面。") }

    if options.editAction != "merge" {
      let delete = try PageSelectionParser.indexes(
        options.deletePages, pageCount: document.pageCount)
      for index in Set(delete).sorted(by: >) { document.removePage(at: index) }
      guard document.pageCount > 0 else {
        throw NativeDocumentError.invalidOption("不能删除全部页面。")
      }

      let rotate = try PageSelectionParser.indexes(
        options.rotatePages, pageCount: document.pageCount)
      guard [90, 180, 270, -90, -180, -270].contains(options.rotateDegrees) || rotate.isEmpty else {
        throw NativeDocumentError.invalidOption("旋转角度必须是 90、180 或 270。")
      }
      for index in Set(rotate) {
        if let page = document.page(at: index) {
          page.rotation = normalizedRotation(page.rotation + options.rotateDegrees)
        }
      }

      let reorder = try PageSelectionParser.indexes(
        options.reorderPages, pageCount: document.pageCount)
      if !reorder.isEmpty {
        guard reorder.count == document.pageCount, Set(reorder).count == document.pageCount else {
          throw NativeDocumentError.invalidOption(
            "页面顺序必须包含当前每一页且每页只出现一次；如需删除页面，请使用删除页。")
        }
        let reordered = PDFDocument()
        for index in reorder {
          guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
          reordered.insert(page, at: reordered.pageCount)
        }
        while document.pageCount > 0 { document.removePage(at: 0) }
        for index in 0..<reordered.pageCount {
          if let page = reordered.page(at: index)?.copy() as? PDFPage {
            document.insert(page, at: document.pageCount)
          }
        }
      }

      let crop = try PageSelectionParser.indexes(options.cropPages, pageCount: document.pageCount)
      if !crop.isEmpty {
        let box = try parseCropBox(options.cropBox)
        for index in Set(crop) {
          document.page(at: index)?.setBounds(box, for: .cropBox)
        }
      }

      let watermark = options.watermark.trimmingCharacters(in: .whitespacesAndNewlines)
      if !watermark.isEmpty {
        for index in 0..<document.pageCount {
          guard let page = document.page(at: index) else { continue }
          let bounds = page.bounds(for: .cropBox)
          let annotationBounds = CGRect(
            x: bounds.minX + bounds.width * 0.12, y: bounds.midY - 32,
            width: bounds.width * 0.76, height: 64)
          let annotation = PDFAnnotation(
            bounds: annotationBounds, forType: .freeText, withProperties: nil)
          annotation.contents = watermark
          annotation.font = NSFont.systemFont(ofSize: 30, weight: .semibold)
          annotation.fontColor = NSColor(calibratedWhite: 0.15, alpha: 0.24)
          annotation.color = .clear
          annotation.alignment = .center
          page.addAnnotation(annotation)
        }
      }
    }

    guard document.write(to: outputURL) else {
      throw NativeDocumentError.processing("无法写入 PDF 结果。")
    }
  }

  private static func imagesToPDF(inputs: [URL], outputURL: URL) throws {
    guard !inputs.isEmpty else { throw NativeDocumentError.invalidFile("没有可用图片。") }
    let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    try withPDFContext(outputURL: outputURL, mediaBox: pageBox) { context in
      for input in inputs {
        try Task.checkCancellation()
        let image = try loadImage(input)
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(pageBox)
        context.interpolationQuality = .high
        context.draw(image, in: aspectFit(image: image, inside: pageBox.insetBy(dx: 30, dy: 30)))
        context.endPDFPage()
      }
    }
  }

  private static func textFilesToPDF(inputs: [URL], source: String, outputURL: URL) throws {
    var combined = ""
    for url in inputs {
      try Task.checkCancellation()
      let data = try Data(contentsOf: url)
      guard let text = String(data: data, encoding: .utf8) else {
        throw NativeDocumentError.invalidFile("\(url.lastPathComponent) 不是 UTF-8 文本。")
      }
      if !combined.isEmpty { combined += "\n\n—— \n\n" }
      combined += source == "html" ? stripHTML(text) : text
    }
    try writeTextPDF(combined, to: outputURL)
  }

  private static func performOCR(inputs: [URL], options: JobOptions, outputURL: URL) async throws {
    let languages = recognitionLanguages(options.ocrLanguage)
    if options.ocrOutputFormat == "text" {
      var recognizedPages: [String] = []
      try forEachRasterPage(inputs: inputs) { image in
        try Task.checkCancellation()
        let text = try recognize(image, languages: languages).map(\.text).joined(separator: "\n")
        recognizedPages.append(text)
      }
      let text = recognizedPages.joined(separator: "\n\n")
      try Data(text.utf8).write(to: outputURL, options: .atomic)
    } else {
      try writeSearchablePDF(inputs: inputs, languages: languages, outputURL: outputURL)
    }
  }

  private static func extractMarkdown(inputs: [URL], options: JobOptions, outputURL: URL)
    async throws
  {
    var sections: [String] = []
    for input in inputs {
      try Task.checkCancellation()
      if input.pathExtension.lowercased() == "pdf" {
        guard let document = PDFDocument(url: input), document.pageCount > 0,
          let rasterDocument = CGPDFDocument(input as CFURL)
        else {
          throw NativeDocumentError.invalidFile(
            "无法打开 \(input.lastPathComponent) 或 PDF 没有页面。")
        }
        var pages: [String] = []
        for index in 0..<document.pageCount {
          try Task.checkCancellation()
          var text =
            document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          if text.isEmpty, !options.ocrLanguage.isEmpty {
            guard let page = rasterDocument.page(at: index + 1),
              let image = render(page: page, maximumDimension: 2200)
            else {
              throw NativeDocumentError.processing(
                "无法渲染 \(input.lastPathComponent) 的第 \(index + 1) 页。")
            }
            text = try recognize(
              image, languages: recognitionLanguages(options.ocrLanguage)
            ).map(\.text).joined(separator: "\n")
          }
          pages.append(text)
        }
        sections.append(pages.joined(separator: "\n\n---\n\n"))
      } else {
        let image = try loadImage(input)
        sections.append(
          try recognize(image, languages: recognitionLanguages(options.ocrLanguage)).map(\.text)
            .joined(separator: "\n"))
      }
    }
    try Data(sections.joined(separator: "\n\n").utf8).write(to: outputURL, options: .atomic)
  }

  private static func translatePDF(
    input: URL, options: JobOptions, outputURL: URL, apiKey: String
  ) async throws {
    guard let document = PDFDocument(url: input), document.pageCount > 0 else {
      throw NativeDocumentError.invalidFile("无法打开 PDF 或 PDF 没有页面。")
    }
    guard let rasterDocument = CGPDFDocument(input as CFURL) else {
      throw NativeDocumentError.invalidFile("无法打开 PDF 图像内容。")
    }
    let translator = TranslationService(provider: options.provider, apiKey: apiKey)
    var pages: [String] = []
    for index in 0..<document.pageCount {
      try Task.checkCancellation()
      var sourceText =
        document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if sourceText.isEmpty {
        guard let page = rasterDocument.page(at: index + 1),
          let image = render(page: page, maximumDimension: 2400)
        else {
          throw NativeDocumentError.processing("无法渲染 PDF 的第 \(index + 1) 页。")
        }
        sourceText = try recognize(
          image, languages: recognitionLanguages(options.ocrLanguage)
        ).map(\.text).joined(separator: "\n")
      }
      guard !sourceText.isEmpty else {
        pages.append("第 \(index + 1) 页没有可提取的文字。")
        continue
      }
      let translated = try await translator.translate(
        sourceText, source: options.sourceLanguage, target: options.targetLanguage,
        glossary: options.glossary)
      if options.outputMode == "bilingual" {
        pages.append("原文\n\(sourceText)\n\n译文\n\(translated)")
      } else {
        pages.append(translated)
      }
    }
    try writeTextPDF(pages.joined(separator: "\n\n────────\n\n"), to: outputURL)
  }

  private static func forEachRasterPage(
    inputs: [URL], body: (CGImage) throws -> Void
  ) throws {
    var processedPageCount = 0
    for input in inputs {
      try Task.checkCancellation()
      if input.pathExtension.lowercased() == "pdf" {
        guard let document = CGPDFDocument(input as CFURL) else {
          throw NativeDocumentError.invalidFile("无法打开 \(input.lastPathComponent)。")
        }
        guard document.numberOfPages > 0 else {
          throw NativeDocumentError.invalidFile("\(input.lastPathComponent) 没有可识别的页面。")
        }
        for pageNumber in 1...document.numberOfPages {
          try Task.checkCancellation()
          guard let page = document.page(at: pageNumber),
            let image = render(page: page, maximumDimension: 2400)
          else {
            throw NativeDocumentError.processing(
              "无法渲染 \(input.lastPathComponent) 的第 \(pageNumber) 页。")
          }
          try body(image)
          processedPageCount += 1
        }
      } else {
        try body(loadImage(input))
        processedPageCount += 1
      }
    }
    guard processedPageCount > 0 else {
      throw NativeDocumentError.invalidFile("没有可识别的页面。")
    }
  }

  private static func recognize(_ image: CGImage, languages: [String]) throws -> [OCRLine] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = languages
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    try handler.perform([request])
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      return OCRLine(text: candidate.string, box: observation.boundingBox)
    }
  }

  private static func writeSearchablePDF(
    inputs: [URL], languages: [String], outputURL: URL
  ) throws {
    let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    try withPDFContext(outputURL: outputURL, mediaBox: pageBox) { context in
      try forEachRasterPage(inputs: inputs) { image in
        try Task.checkCancellation()
        let recognized = try recognize(image, languages: languages)
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(pageBox)
        let imageRect = aspectFit(image: image, inside: pageBox)
        context.draw(image, in: imageRect)
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in recognized {
          let rect = CGRect(
            x: imageRect.minX + line.box.minX * imageRect.width,
            y: imageRect.minY + line.box.minY * imageRect.height,
            width: line.box.width * imageRect.width,
            height: line.box.height * imageRect.height)
          drawLine(line.text, in: rect, context: context)
        }
        context.restoreGState()
        context.endPDFPage()
      }
    }
  }

  private static func writeTextPDF(_ text: String, to outputURL: URL) throws {
    let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    let contentBox = pageBox.insetBy(dx: 52, dy: 54)
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          "PingFangSC-Regular" as CFString, 11.5, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor(
          calibratedRed: 0.12, green: 0.14, blue: 0.13, alpha: 1
        ).cgColor,
      ])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    var location = 0
    try withPDFContext(outputURL: outputURL, mediaBox: pageBox) { context in
      repeat {
        try Task.checkCancellation()
        context.beginPDFPage(nil)
        context.setFillColor(
          NSColor(calibratedRed: 0.96, green: 0.965, blue: 0.95, alpha: 1).cgColor)
        context.fill(pageBox)
        let path = CGPath(rect: contentBox, transform: nil)
        let frame = CTFramesetterCreateFrame(
          framesetter, CFRange(location: location, length: 0), path, nil)
        CTFrameDraw(frame, context)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else {
          throw NativeDocumentError.processing("文本排版失败。")
        }
        location += visible.length
        context.endPDFPage()
      } while location < attributed.length
    }
  }

  private static func drawLine(_ text: String, in rect: CGRect, context: CGContext) {
    let fontSize = max(5, min(24, rect.height * 0.82))
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          "Helvetica" as CFString, fontSize, nil)
      ])
    let line = CTLineCreateWithAttributedString(attributed)
    context.textPosition = CGPoint(x: rect.minX, y: rect.minY + max(0, rect.height - fontSize) / 2)
    CTLineDraw(line, context)
  }

  private static func withPDFContext(
    outputURL: URL, mediaBox: CGRect, body: (CGContext) throws -> Void
  ) throws {
    guard let consumer = CGDataConsumer(url: outputURL as CFURL) else {
      throw NativeDocumentError.processing("无法创建 PDF 文件。")
    }
    var box = mediaBox
    guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
      throw NativeDocumentError.processing("无法创建 PDF 绘图环境。")
    }
    defer { context.closePDF() }
    try body(context)
  }

  static func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw NativeDocumentError.invalidFile("无法读取图片 \(url.lastPathComponent)。")
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 1
    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 1
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      throw NativeDocumentError.invalidFile("无法解码图片 \(url.lastPathComponent)。")
    }
    return image
  }

  private static func render(page: CGPDFPage, maximumDimension: CGFloat) -> CGImage? {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let scale = min(maximumDimension / max(box.width, box.height), 3)
    let width = max(1, Int((box.width * scale).rounded(.up)))
    let height = max(1, Int((box.height * scale).rounded(.up)))
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.saveGState()
    let target = CGRect(x: 0, y: 0, width: width, height: height)
    context.concatenate(
      page.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
    context.drawPDFPage(page)
    context.restoreGState()
    return context.makeImage()
  }

  private static func aspectFit(image: CGImage, inside box: CGRect) -> CGRect {
    let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
    let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
    return CGRect(
      x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width,
      height: size.height)
  }

  private static func normalizedRotation(_ value: Int) -> Int {
    let normalized = value % 360
    return normalized < 0 ? normalized + 360 : normalized
  }

  private static func parseCropBox(_ value: String) throws -> CGRect {
    let values = value.split(separator: ",").compactMap {
      Double($0.trimmingCharacters(in: .whitespaces))
    }
    guard values.count == 4, values[2] > values[0], values[3] > values[1] else {
      throw NativeDocumentError.invalidOption("裁剪区域必须是 x0,y0,x1,y1，且右下坐标大于左上坐标。")
    }
    return CGRect(
      x: values[0], y: values[1], width: values[2] - values[0], height: values[3] - values[1])
  }

  private static func recognitionLanguages(_ value: String) -> [String] {
    let normalized =
      value
      .replacingOccurrences(of: "+", with: ",")
      .split(separator: ",")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    let mapped = normalized.compactMap { language -> String? in
      switch language.lowercased() {
      case "chi_sim", "zh", "zh-cn", "zh-hans": "zh-Hans"
      case "chi_tra", "zh-tw", "zh-hant": "zh-Hant"
      case "eng", "en": "en-US"
      default: language.isEmpty ? nil : language
      }
    }
    return mapped.isEmpty ? ["zh-Hans", "en-US"] : mapped
  }

  private static func stripHTML(_ source: String) -> String {
    let withoutScripts = source.replacingOccurrences(
      of: "<script[\\s\\S]*?</script>|<style[\\s\\S]*?</style>", with: " ",
      options: [.regularExpression, .caseInsensitive])
    return withoutScripts.replacingOccurrences(
      of: "<[^>]+>", with: " ", options: .regularExpression
    )
    .replacingOccurrences(of: "&nbsp;", with: " ")
    .replacingOccurrences(of: "&amp;", with: "&")
    .replacingOccurrences(of: "&lt;", with: "<")
    .replacingOccurrences(of: "&gt;", with: ">")
  }
}

struct TranslationService {
  static let maximumGlossaryCharacters = 20_000

  let provider: String
  let apiKey: String

  func translate(_ text: String, source: String, target: String, glossary: String) async throws
    -> String
  {
    var translated: [String] = []
    for chunk in Self.chunks(text) {
      try Task.checkCancellation()
      translated.append(
        try await translateChunk(chunk, source: source, target: target, glossary: glossary))
    }
    return translated.joined(separator: "\n\n")
  }

  static func chunks(_ text: String, maximumCharacters: Int = 12_000) -> [String] {
    guard maximumCharacters > 0, text.count > maximumCharacters else { return [text] }
    var result: [String] = []
    var current = ""
    func flush() {
      let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { result.append(trimmed) }
      current = ""
    }
    for paragraph in text.components(separatedBy: "\n\n") {
      if paragraph.count > maximumCharacters {
        flush()
        var start = paragraph.startIndex
        while start < paragraph.endIndex {
          let end =
            paragraph.index(
              start, offsetBy: maximumCharacters, limitedBy: paragraph.endIndex)
            ?? paragraph.endIndex
          result.append(String(paragraph[start..<end]))
          start = end
        }
      } else if current.isEmpty {
        current = paragraph
      } else if current.count + paragraph.count + 2 <= maximumCharacters {
        current += "\n\n" + paragraph
      } else {
        flush()
        current = paragraph
      }
    }
    flush()
    return result
  }

  private func translateChunk(
    _ text: String, source: String, target: String, glossary: String
  ) async throws -> String {
    let isOpenAI = provider == "openai"
    let endpoint = URL(
      string: isOpenAI
        ? "https://api.openai.com/v1/chat/completions" : "https://api.deepseek.com/chat/completions"
    )!
    let model = isOpenAI ? "gpt-4o-mini" : "deepseek-chat"
    let glossaryInstruction =
      glossary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "" : "\n术语表：\n\(glossary)"
    let prompt = """
      将以下文档文字从 \(source) 翻译为 \(target)。保留段落、标题、列表和数字。只返回译文，不解释。\(glossaryInstruction)

      \(text)
      """
    let payload: [String: Any] = [
      "model": model,
      "messages": [
        ["role": "system", "content": "你是严谨的文档翻译器。"],
        ["role": "user", "content": prompt],
      ],
      "temperature": 0.1,
    ]
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
      if Task.isCancelled || error.code == .cancelled { throw CancellationError() }
      throw Self.providerError(for: error)
    }
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw NativeDocumentError.provider("翻译服务返回了无效响应。")
    }
    guard (200..<300).contains(http.statusCode) else {
      let message = Self.errorMessage(data) ?? "HTTP \(http.statusCode)"
      throw NativeDocumentError.provider("翻译服务请求失败：\(message)")
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let choices = object["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any],
      let content = message["content"] as? String, !content.isEmpty
    else {
      throw NativeDocumentError.provider("翻译服务没有返回译文。")
    }
    return content
  }

  private static func errorMessage(_ data: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let error = object["error"] as? [String: Any]
    else { return nil }
    return error["message"] as? String
  }

  static func providerError(for error: URLError) -> NativeDocumentError {
    switch error.code {
    case .notConnectedToInternet:
      .provider("当前没有网络连接，联网后再试。")
    case .timedOut:
      .provider("翻译服务响应超时，请稍后重试或减少单次处理内容。")
    case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
      .provider("无法连接翻译服务，请检查网络、代理或 VPN。")
    case .secureConnectionFailed, .serverCertificateHasBadDate,
      .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
      .provider("无法建立安全连接，请检查系统时间和网络证书。")
    default:
      .provider("翻译服务连接失败：\(error.localizedDescription)")
    }
  }
}
