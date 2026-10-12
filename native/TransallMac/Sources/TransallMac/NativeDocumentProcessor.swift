import PDFKit
import Vision

enum NativeDocumentProcessor {
  static let maximumPDFImageDimension = 3_508
  static let maximumOCRImageDimension = 2_400

  struct Result: Sendable {
    let outputURL: URL
    let logs: [String]
  }

  private struct OCRLine {
    let text: String
    let box: CGRect
  }

  private struct IncrementalUTF8Writer {
    private let handle: FileHandle
    private var hasEntry = false

    init(outputURL: URL) throws {
      try Data().write(to: outputURL, options: .atomic)
      handle = try FileHandle(forWritingTo: outputURL)
    }

    mutating func append(_ text: String, separator: String) throws {
      if hasEntry, !separator.isEmpty {
        try handle.write(contentsOf: Data(separator.utf8))
      }
      if !text.isEmpty {
        try handle.write(contentsOf: Data(text.utf8))
      }
      hasEntry = true
    }

    func close() throws {
      try handle.close()
    }

    func closeIgnoringErrors() {
      try? handle.close()
    }
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
    try JobOptionValidator.validate(route: route, options: options)
    await ProcessingProgress.report("正在处理文档")
    switch route.kind {
    case "pdf_edit":
      try editPDF(inputs: inputs, options: options, outputURL: outputURL)
      return Result(outputURL: outputURL, logs: ["PDF 已使用 PDFKit 处理。"])
    case "image_to_pdf":
      try imagesToPDF(inputs: inputs, outputURL: outputURL)
      return Result(outputURL: outputURL, logs: ["图片已按文件顺序写入 PDF。"])
    case "office_convert":
      try await OfficeDocumentConverter.convert(
        inputs: inputs, source: route.source, target: route.target, output: outputURL)
      return Result(outputURL: outputURL, logs: ["Office 文档已在本机转换。"])
    case "text_to_pdf":
      try await WebDocumentConverter.convert(
        inputs: inputs, source: route.source, target: "pdf", output: outputURL)
      return Result(outputURL: outputURL, logs: ["文档已使用系统排版生成 PDF；未加载外部网络资源。"])
    case "ocr":
      try await performOCR(inputs: inputs, options: options, outputURL: outputURL)
      return Result(outputURL: outputURL, logs: ["文字识别在本机使用 Apple Vision 完成。"])
    case "extract_markdown":
      if ["html", "data"].contains(route.source) {
        try await WebDocumentConverter.convert(
          inputs: inputs, source: route.source, target: "md", output: outputURL)
      } else {
        try await extractMarkdown(inputs: inputs, options: options, outputURL: outputURL)
      }
      return Result(outputURL: outputURL, logs: ["文字已提取为 Markdown。"])
    case "pdf_translate":
      guard inputs.count == 1, let input = inputs.first else {
        throw NativeDocumentError.invalidFile("PDF 翻译每次只能使用一个文件。")
      }
      guard let apiKey else {
        throw NativeDocumentError.provider("所选翻译服务尚未配置 API Key。")
      }
      let validatedAPIKey: String
      do {
        validatedAPIKey = try ProviderCredentialPolicy.normalizedValue(
          apiKey, allowingEmpty: false)
      } catch let error as ProviderCredentialValidationError {
        if error == .missing {
          throw NativeDocumentError.provider("所选翻译服务尚未配置 API Key。")
        }
        throw NativeDocumentError.provider("API Key 格式无效：\(error.localizedDescription)")
      }
      let layoutReport = try await translatePDF(
        input: input, options: options, outputURL: outputURL, apiKey: validatedAPIKey)
      var logs = [
        "文档文字已发送给 \(options.provider == "openai" ? "OpenAI" : "DeepSeek") 并生成译文 PDF。"
      ]
      if let layoutReport {
        if !layoutReport.supplementedRegionIDs.isEmpty {
          logs.append("已自动将 \(layoutReport.supplementedRegionIDs.count) 处较长译文放入文末补充页。")
        }
        logs.append(
          "保留原版式：\(layoutReport.nativeRegionCount) 个原生文字区域，\(layoutReport.imageOCRRegionCount) 个图片文字区域。"
        )
      }
      return Result(
        outputURL: outputURL,
        logs: logs)
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
    var document: PDFDocument
    if options.editAction == "merge" {
      guard inputs.count >= 2 else {
        throw NativeDocumentError.invalidFile("合并 PDF 至少需要两个文件。")
      }
      let merged = PDFDocument()
      for input in inputs {
        try Task.checkCancellation()
        guard let source = PDFDocument(url: input) else {
          throw NativeDocumentError.invalidFile("无法打开 \(input.lastPathComponent)。")
        }
        for index in 0..<source.pageCount {
          try Task.checkCancellation()
          guard let page = source.page(at: index)?.copy() as? PDFPage else {
            throw NativeDocumentError.invalidFile(
              "无法读取 \(input.lastPathComponent) 的第 \(index + 1) 页。")
          }
          merged.insert(page, at: merged.pageCount)
        }
      }
      document = merged
    } else {
      guard inputs.count == 1, let input = inputs.first else {
        throw NativeDocumentError.invalidFile("编辑单个 PDF 时只能使用一个文件。")
      }
      try Task.checkCancellation()
      guard let source = PDFDocument(url: input) else {
        throw NativeDocumentError.invalidFile("无法打开 \(input.lastPathComponent)。")
      }
      document = source
    }
    guard document.pageCount > 0 else { throw NativeDocumentError.invalidFile("PDF 没有可用页面。") }

    if options.editAction != "merge" {
      let delete = try PageSelectionParser.indexes(
        options.deletePages, pageCount: document.pageCount)
      for index in Set(delete).sorted(by: >) {
        try Task.checkCancellation()
        document.removePage(at: index)
      }
      guard document.pageCount > 0 else {
        throw NativeDocumentError.invalidOption("不能删除全部页面。")
      }

      let rotate = try PageSelectionParser.indexes(
        options.rotatePages, pageCount: document.pageCount)
      guard [90, 180, 270, -90, -180, -270].contains(options.rotateDegrees) || rotate.isEmpty else {
        throw NativeDocumentError.invalidOption("旋转角度必须是 90、180 或 270。")
      }
      for index in Set(rotate) {
        try Task.checkCancellation()
        guard let page = document.page(at: index) else {
          throw NativeDocumentError.processing("无法读取第 \(index + 1) 页以旋转。")
        }
        page.rotation = normalizedRotation(page.rotation + options.rotateDegrees)
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
          try Task.checkCancellation()
          guard let page = document.page(at: index)?.copy() as? PDFPage else {
            throw NativeDocumentError.processing("无法复制第 \(index + 1) 页以调整顺序。")
          }
          reordered.insert(page, at: reordered.pageCount)
        }
        document = reordered
      }

      let crop = try PageSelectionParser.indexes(options.cropPages, pageCount: document.pageCount)
      if !crop.isEmpty {
        let box = try JobOptionValidator.parseCropBox(options.cropBox)
        var pagesToCrop: [(index: Int, page: PDFPage)] = []
        for index in Set(crop).sorted() {
          try Task.checkCancellation()
          guard let page = document.page(at: index) else {
            throw NativeDocumentError.processing("无法读取第 \(index + 1) 页以裁剪。")
          }
          guard page.bounds(for: .cropBox).contains(box) else {
            throw NativeDocumentError.invalidOption("裁剪区域超出第 \(index + 1) 页当前页面范围。")
          }
          pagesToCrop.append((index, page))
        }
        for (index, page) in pagesToCrop {
          try Task.checkCancellation()
          page.setBounds(box, for: .cropBox)
          guard cropBoxesMatch(page.bounds(for: .cropBox), box) else {
            throw NativeDocumentError.processing("无法按指定区域裁剪第 \(index + 1) 页。")
          }
        }
      }

      try PDFTextReplacement.apply(
        to: document, find: options.replaceFind ?? "", replacement: options.replaceWith ?? "")

      let watermark = options.watermark.trimmingCharacters(in: .whitespacesAndNewlines)
      if !watermark.isEmpty {
        for index in 0..<document.pageCount {
          try Task.checkCancellation()
          guard let page = document.page(at: index) else {
            throw NativeDocumentError.processing("无法读取第 \(index + 1) 页以添加水印。")
          }
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

    try Task.checkCancellation()
    guard document.write(to: outputURL) else {
      throw NativeDocumentError.processing("无法写入 PDF 结果。")
    }
    try Task.checkCancellation()
  }

  private static func imagesToPDF(inputs: [URL], outputURL: URL) throws {
    guard !inputs.isEmpty else { throw NativeDocumentError.invalidFile("没有可用图片。") }
    let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    try withPDFContext(outputURL: outputURL, mediaBox: pageBox) { context in
      for input in inputs {
        try Task.checkCancellation()
        let image = try loadImage(input, maximumDimension: maximumPDFImageDimension)
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
    let totalBytes = try validatedTextInputSize(inputs)
    var combined = ""
    combined.reserveCapacity(totalBytes)
    for url in inputs {
      try Task.checkCancellation()
      let data = try Data(contentsOf: url, options: .mappedIfSafe)
      guard let text = String(data: data, encoding: .utf8) else {
        throw NativeDocumentError.invalidFile("\(url.lastPathComponent) 不是 UTF-8 文本。")
      }
      if !combined.isEmpty { combined += "\n\n—— \n\n" }
      combined += source == "html" ? stripHTML(text) : text
    }
    if source == "md" {
      try MarkdownPDFRenderer.write(combined, to: outputURL)
    } else {
      try writeTextPDF(combined, to: outputURL)
    }
  }

  private static func validatedTextInputSize(_ inputs: [URL]) throws -> Int {
    var total = 0
    for input in inputs {
      try Task.checkCancellation()
      let values = try input.resourceValues(forKeys: [.fileSizeKey])
      guard let fileSize = values.fileSize, fileSize >= 0 else {
        throw NativeDocumentError.invalidFile("无法读取 \(input.lastPathComponent) 的文件大小。")
      }
      let addition = total.addingReportingOverflow(fileSize)
      total = addition.overflow ? Int.max : addition.partialValue
      guard total <= NativeCapabilities.textToPDFLimitBytes else {
        throw NativeDocumentError.invalidFile(
          "文本转 PDF 的输入总计超过 \(NativeCapabilities.textToPDFLimitMB) MB。")
      }
    }
    return total
  }

  private static func performOCR(inputs: [URL], options: JobOptions, outputURL: URL) async throws {
    let languages = recognitionLanguages(options.ocrLanguage)
    if options.ocrOutputFormat == "text" {
      var writer = try IncrementalUTF8Writer(outputURL: outputURL)
      do {
        try forEachRasterPage(inputs: inputs) { image in
          try Task.checkCancellation()
          let text = try recognize(image, languages: languages).map(\.text).joined(separator: "\n")
          try writer.append(text, separator: "\n\n")
        }
        try writer.close()
      } catch {
        writer.closeIgnoringErrors()
        throw error
      }
    } else {
      try writeSearchablePDF(inputs: inputs, languages: languages, outputURL: outputURL)
    }
  }

  private static func extractMarkdown(inputs: [URL], options: JobOptions, outputURL: URL)
    async throws
  {
    var writer = try IncrementalUTF8Writer(outputURL: outputURL)
    do {
      for input in inputs {
        try Task.checkCancellation()
        if input.pathExtension.lowercased() == "pdf" {
          guard let document = PDFDocument(url: input), document.pageCount > 0,
            let rasterDocument = CGPDFDocument(input as CFURL)
          else {
            throw NativeDocumentError.invalidFile(
              "无法打开 \(input.lastPathComponent) 或 PDF 没有页面。")
          }
          for index in 0..<document.pageCount {
            try Task.checkCancellation()
            var text =
              document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
              ?? ""
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
            try writer.append(text, separator: index == 0 ? "\n\n" : "\n\n---\n\n")
          }
        } else {
          let image = try loadImage(input, maximumDimension: maximumOCRImageDimension)
          let text = try recognize(
            image, languages: recognitionLanguages(options.ocrLanguage)
          ).map(\.text).joined(separator: "\n")
          try writer.append(text, separator: "\n\n")
        }
      }
      try writer.close()
    } catch {
      writer.closeIgnoringErrors()
      throw error
    }
  }

  private static func translatePDF(
    input: URL, options: JobOptions, outputURL: URL, apiKey: String
  ) async throws -> PDFLayoutTranslationReport? {
    await ProcessingProgress.report("正在提取原文")
    let sourceSHA256 =
      options.outputMode != "translated"
      ? try TranslationRecoveryStore.sourceFingerprint(inputURL: input) : nil
    guard let document = PDFDocument(url: input), document.pageCount > 0 else {
      throw NativeDocumentError.invalidFile("无法打开 PDF 或 PDF 没有页面。")
    }
    guard let rasterDocument = CGPDFDocument(input as CFURL) else {
      throw NativeDocumentError.invalidFile("无法打开 PDF 图像内容。")
    }
    if options.outputMode != "translated" {
      try PDFTranslationPolicy.validate(pageCount: document.pageCount)
      let regions = try PDFLayoutTranslation.extractRegions(
        document: document, rasterDocument: rasterDocument,
        languages: recognitionLanguages(options.ocrLanguage))
      guard !regions.isEmpty else {
        throw NativeDocumentError.invalidFile("PDF 中没有可翻译的文字。")
      }
      var totalCharacters = 0
      for region in regions {
        totalCharacters = try PDFTranslationPolicy.totalCharacters(
          afterAdding: region.sourceText.count, to: totalCharacters)
      }
      let translator = TranslationService(
        provider: options.provider, apiKey: apiKey, pageConcurrency: 4)
      await ProcessingProgress.report("正在分析文档主题与术语")
      let documentContext = try await translator.analyzeDocument(
        regions, source: options.sourceLanguage, target: options.targetLanguage)
      try documentContext.write(
        to: outputURL.deletingLastPathComponent().appendingPathComponent("document-context.txt"),
        atomically: true, encoding: .utf8)
      let directory = outputURL.deletingLastPathComponent()
      let existing = TranslationRecoveryStore.resumableTranslations(
        in: directory, inputURL: input, options: options, regions: regions)
      let pageCount = document.pageCount
      let translations = try await translator.translateRegions(
        regions, source: options.sourceLanguage, target: options.targetLanguage,
        glossary: options.glossary, documentContext: documentContext,
        existingTranslations: existing,
        checkpoint: { translated in
          let saved = try TranslationRecoveryStore.create(
            inputURL: input, options: options, pageCount: pageCount, regions: regions,
            translations: translated, overflowRegionIDs: [], allowingIncomplete: true)
          guard saved.sourceSHA256 == sourceSHA256 else {
            throw NativeDocumentError.processing("翻译期间原文件发生变化，已停止保存。")
          }
          try TranslationRecoveryStore.save(saved, in: directory, allowingIncomplete: true)
        })
      await ProcessingProgress.report("正在排版译文")
      let report = try finishLayoutTranslation(
        input: input, options: options, pageCount: document.pageCount, regions: regions,
        translations: translations, outputURL: outputURL, expectedSourceSHA256: sourceSHA256)
      if options.outputMode == "bilingual" {
        try PDFLayoutTranslation.pairOriginalAndTranslation(inputURL: input, outputURL: outputURL)
      }
      return report
    }
    let sourcePages = try translationSourcePages(
      document: document, rasterDocument: rasterDocument, options: options)
    let translator = TranslationService(
      provider: options.provider, apiKey: apiKey, pageConcurrency: 4)
    let pages = try await translator.translatePages(
      sourcePages, source: options.sourceLanguage, target: options.targetLanguage,
      glossary: options.glossary)
    await ProcessingProgress.report("正在排版译文")
    try writeTextPDF(pages.joined(separator: "\n\n────────\n\n"), to: outputURL)
    return nil
  }

  // Shared by production and tests: completed provider work is persisted before any layout work.
  static func finishLayoutTranslation(
    input: URL, options: JobOptions, pageCount: Int, regions: [PDFTranslationRegion],
    translations: [String: String], outputURL: URL, expectedSourceSHA256: String? = nil
  ) throws -> PDFLayoutTranslationReport {
    var recovery = try TranslationRecoveryStore.create(
      inputURL: input, options: options, pageCount: pageCount, regions: regions,
      translations: translations, overflowRegionIDs: [])
    if let expectedSourceSHA256, recovery.sourceSHA256 != expectedSourceSHA256 {
      throw NativeDocumentError.invalidFile("输入文件在翻译期间发生变化，未保存不匹配的译文。")
    }
    let directory = outputURL.deletingLastPathComponent()
    try TranslationRecoveryStore.save(recovery, in: directory)
    do {
      let report = try PDFLayoutTranslation.writeTranslatedPDF(
        inputURL: input, regions: regions, translations: translations, outputURL: outputURL,
        automaticallySupplementOverflow: true)
      guard report.overflowRegionIDs.isEmpty else {
        recovery.overflowRegionIDs = report.overflowRegionIDs
        try TranslationRecoveryStore.save(recovery, in: directory)
        throw NativeDocumentError.layoutOverflow(report.overflowRegionIDs.count)
      }
      // The complete cache is already stored; a successful layout adds no recovery metadata.
      try TranslationRecoveryStore.validateForRendering(recovery)
      return report
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }

  static func renderRecoveredTranslation(
    _ document: TranslationRecoveryDocument, to outputURL: URL,
    layoutInputURL: URL? = nil, bilingual: Bool = false
  ) throws -> Result {
    try TranslationRecoveryStore.validateForRendering(document)
    if let input = layoutInputURL {
      guard try TranslationRecoveryStore.sourceFingerprint(inputURL: input) == document.sourceSHA256
      else {
        throw NativeDocumentError.processing("原文件与已保存译文不一致。")
      }
      do {
        let report = try PDFLayoutTranslation.writeTranslatedPDF(
          inputURL: input, regions: document.regions,
          translations: document.translations, outputURL: outputURL,
          automaticallySupplementOverflow: true)
        guard report.overflowRegionIDs.isEmpty else {
          throw NativeDocumentError.layoutOverflow(report.overflowRegionIDs.count)
        }
        if bilingual {
          try PDFLayoutTranslation.pairOriginalAndTranslation(inputURL: input, outputURL: outputURL)
        }
        try TranslationRecoveryStore.validateForRendering(document)
        return Result(
          outputURL: outputURL,
          logs: [
            "已使用本机保存的译文生成 \(document.pageCount) 页\(bilingual ? "左右对照" : "保留版式") PDF，未再次读取密钥或请求翻译服务。"
          ])
      } catch {
        try? FileManager.default.removeItem(at: outputURL)
        throw error
      }
    }
    let byPage = Dictionary(grouping: document.regions, by: \.pageIndex)
    // Dictionary grouping retains extraction order within each original page.
    let pages = (0..<document.pageCount).map { index in
      let translated = byPage[index, default: []].compactMap {
        document.translations[$0.id]
      }.joined(separator: "\n\n")
      return "原文第 \(index + 1) 页\n\n"
        + (translated.isEmpty ? "本页没有可翻译的文字。" : translated)
    }
    do {
      try writeTextPDF(pages: pages, to: outputURL)
      try TranslationRecoveryStore.validateForRendering(document)
      return Result(
        outputURL: outputURL,
        logs: [
          "已使用本机保存的全部译文生成纯译文 PDF，未再次调用翻译服务。",
          "保留原文 \(document.pageCount) 页的顺序和页内文字区域顺序，各原文页从新页开始。",
        ])
    } catch {
      try? FileManager.default.removeItem(at: outputURL)
      throw error
    }
  }

  private static func translationSourcePages(
    document: PDFDocument, rasterDocument: CGPDFDocument, options: JobOptions
  ) throws -> [String] {
    try PDFTranslationPolicy.validate(pageCount: document.pageCount)
    var pages: [String] = []
    pages.reserveCapacity(document.pageCount)
    var totalCharacters = 0
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
      totalCharacters = try PDFTranslationPolicy.totalCharacters(
        afterAdding: sourceText.count, to: totalCharacters)
      pages.append(sourceText)
    }
    return pages
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
        try body(loadImage(input, maximumDimension: maximumOCRImageDimension))
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
    try writeTextPDF(pages: [text], to: outputURL)
  }

  private static func writeTextPDF(pages: [String], to outputURL: URL) throws {
    let pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
    let contentBox = pageBox.insetBy(dx: 52, dy: 54)
    try withPDFContext(outputURL: outputURL, mediaBox: pageBox) { context in
      for text in pages {
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

  static func loadImage(
    _ url: URL, maximumDimension: Int = maximumPDFImageDimension
  ) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw NativeDocumentError.invalidFile("无法读取图片 \(url.lastPathComponent)。")
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
    guard width > 0, height > 0 else {
      throw NativeDocumentError.invalidFile("无法读取图片尺寸 \(url.lastPathComponent)。")
    }
    let thumbnailDimension = max(1, min(maximumDimension, max(width, height)))
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: thumbnailDimension,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      throw NativeDocumentError.invalidFile("无法解码图片 \(url.lastPathComponent)。")
    }
    return image
  }

  static func render(page: CGPDFPage, maximumDimension: CGFloat) -> CGImage? {
    let box = page.getBoxRect(.mediaBox)
    guard box.width > 0, box.height > 0 else { return nil }
    let rotation = normalizedRotation(Int(page.rotationAngle))
    let quarterTurn = rotation == 90 || rotation == 270
    let drawingSize = CGSize(
      width: quarterTurn ? box.height : box.width,
      height: quarterTurn ? box.width : box.height)
    let scale = min(maximumDimension / max(drawingSize.width, drawingSize.height), 3)
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
    context.saveGState()
    // Fit in page coordinates first, then explicitly scale into raster pixels.
    // getDrawingTransform can center an unscaled page in a larger destination.
    let pageTransform = page.getDrawingTransform(
      .mediaBox,
      rect: CGRect(origin: .zero, size: drawingSize), rotate: 0, preserveAspectRatio: true)
    context.concatenate(pageTransform.concatenating(CGAffineTransform(scaleX: scale, y: scale)))
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

  private static func cropBoxesMatch(_ actual: CGRect, _ requested: CGRect) -> Bool {
    let tolerance: CGFloat = 0.001
    return abs(actual.minX - requested.minX) <= tolerance
      && abs(actual.minY - requested.minY) <= tolerance
      && abs(actual.width - requested.width) <= tolerance
      && abs(actual.height - requested.height) <= tolerance
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
