import Foundation

enum PageSelectionParser {
  private struct PageRange {
    let first: Int
    let last: Int
  }

  static func indexes(_ specification: String, pageCount: Int) throws -> [Int] {
    let ranges = try ranges(specification)
    var result: [Int] = []
    for range in ranges {
      for page in range.first...range.last {
        try append(page, pageCount: pageCount, to: &result)
      }
    }
    return result
  }

  static func validateSyntax(_ specification: String) throws {
    _ = try ranges(specification)
  }

  private static func ranges(_ specification: String) throws -> [PageRange] {
    let text = specification.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return [] }
    var result: [PageRange] = []
    for rawPart in text.split(separator: ",", omittingEmptySubsequences: false) {
      let part = rawPart.trimmingCharacters(in: .whitespaces)
      guard !part.isEmpty else {
        throw NativeDocumentError.invalidOption("页码格式无效：请使用 2,4-6 这样的格式。")
      }
      let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
      if bounds.count == 1, let page = Int(bounds[0]) {
        result.append(PageRange(first: page, last: page))
      } else if bounds.count == 2, let first = Int(bounds[0]), let last = Int(bounds[1]),
        first <= last
      {
        result.append(PageRange(first: first, last: last))
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

struct JobOptionValidationIssue: Equatable {
  let code: String
  let message: String
  let hint: String?
}

enum JobOptionValidator {
  static let maximumLanguageCharacters = 64
  static let maximumOCRLanguageCharacters = 256
  static let maximumPageSelectionCharacters = 4_096
  static let maximumCropBoxCharacters = 256
  static let maximumWatermarkCharacters = 512

  static func issues(
    for route: RouteDefinition, options: JobOptions
  ) -> [JobOptionValidationIssue] {
    switch route.kind {
    case "pdf_edit":
      pdfEditIssues(options)
    case "pdf_translate":
      translationIssues(options)
    case "ocr":
      ocrIssues(options, validatesOutputFormat: true)
    case "extract_markdown":
      ocrIssues(options, validatesOutputFormat: false)
    default:
      []
    }
  }

  static func validate(route: RouteDefinition, options: JobOptions) throws {
    guard let issue = issues(for: route, options: options).first else { return }
    let message = [issue.message, issue.hint].compactMap { $0 }.joined(separator: "：")
    throw NativeDocumentError.invalidOption(message)
  }

  static func parseCropBox(_ value: String) throws -> CGRect {
    let invalidMessage = "裁剪区域必须是 x0,y0,x1,y1，且右下坐标大于左上坐标。"
    let components = value.split(separator: ",", omittingEmptySubsequences: false)
    guard components.count == 4 else {
      throw NativeDocumentError.invalidOption(invalidMessage)
    }
    var values: [Double] = []
    values.reserveCapacity(components.count)
    for component in components {
      let trimmed = component.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, let number = Double(trimmed) else {
        throw NativeDocumentError.invalidOption(invalidMessage)
      }
      values.append(number)
    }
    let width = values[2] - values[0]
    let height = values[3] - values[1]
    guard values.allSatisfy({ $0.isFinite }), values[2] > values[0],
      values[3] > values[1], width.isFinite, height.isFinite, width > 0, height > 0
    else {
      throw NativeDocumentError.invalidOption(invalidMessage)
    }
    return CGRect(x: values[0], y: values[1], width: width, height: height)
  }

  private static func pdfEditIssues(_ options: JobOptions) -> [JobOptionValidationIssue] {
    guard ["edit", "merge"].contains(options.editAction) else {
      return [
        JobOptionValidationIssue(
          code: "invalid_edit_action", message: "PDF 操作无效。",
          hint: "请重新选择编辑单个 PDF 或按列表顺序合并 PDF。")
      ]
    }
    guard options.editAction == "edit" else { return [] }

    var issues: [JobOptionValidationIssue] = []
    let pageSelections = [
      ("删除页", options.deletePages),
      ("旋转页", options.rotatePages),
      ("页面顺序", options.reorderPages),
      ("裁剪页", options.cropPages),
    ]
    for (label, specification) in pageSelections {
      if specification.count > maximumPageSelectionCharacters {
        issues.append(
          JobOptionValidationIssue(
            code: "page_selection_too_large", message: "\(label)内容过长。",
            hint: "请控制在 \(maximumPageSelectionCharacters) 个字符以内。"))
        continue
      }
      do {
        try PageSelectionParser.validateSyntax(specification)
      } catch {
        issues.append(
          JobOptionValidationIssue(
            code: "invalid_page_selection", message: "\(label)格式无效。",
            hint: error.localizedDescription))
      }
    }
    if !options.rotatePages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      ![90, 180, 270, -90, -180, -270].contains(options.rotateDegrees)
    {
      issues.append(
        JobOptionValidationIssue(
          code: "invalid_rotation", message: "旋转角度无效。",
          hint: "旋转角度必须是 90、180 或 270。"))
    }
    if !options.cropPages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      if options.cropBox.count > maximumCropBoxCharacters {
        issues.append(
          JobOptionValidationIssue(
            code: "crop_box_too_large", message: "裁剪区域内容过长。",
            hint: "请控制在 \(maximumCropBoxCharacters) 个字符以内。"))
      } else {
        do {
          _ = try parseCropBox(options.cropBox)
        } catch {
          issues.append(
            JobOptionValidationIssue(
              code: "invalid_crop_box", message: "裁剪区域无效。",
              hint: error.localizedDescription))
        }
      }
    }
    let find = options.replaceFind ?? ""
    let replacement = options.replaceWith ?? ""
    if find.count > 512 || replacement.count > 512 || find.contains("\n")
      || replacement.contains("\n") || (find.isEmpty && !replacement.isEmpty)
    {
      issues.append(
        JobOptionValidationIssue(
          code: "invalid_text_replacement", message: "查找替换需使用单行文字，每项最多 512 字；请先填写查找内容。", hint: nil))
    }
    if options.watermark.count > maximumWatermarkCharacters {
      issues.append(
        JobOptionValidationIssue(
          code: "watermark_too_large", message: "水印文字过长。",
          hint: "请控制在 \(maximumWatermarkCharacters) 个字符以内。"))
    }
    return issues
  }

  private static func translationIssues(_ options: JobOptions) -> [JobOptionValidationIssue] {
    var issues: [JobOptionValidationIssue] = []
    if !["deepseek", "openai"].contains(options.provider) {
      issues.append(
        JobOptionValidationIssue(
          code: "invalid_provider", message: "翻译服务无效。",
          hint: "请在翻译选项中重新选择 DeepSeek 或 OpenAI。"))
    }
    if !["preserve_layout", "translated", "bilingual"].contains(options.outputMode) {
      issues.append(
        JobOptionValidationIssue(
          code: "invalid_translation_output", message: "翻译输出模式无效。",
          hint: "请重新选择纯译文 PDF 或双语对照 PDF。"))
    }
    if let issue = languageIssue(
      options.sourceLanguage, code: "invalid_source_language", label: "源语言")
    {
      issues.append(issue)
    }
    if let issue = languageIssue(
      options.targetLanguage, code: "invalid_target_language", label: "目标语言")
    {
      issues.append(issue)
    }
    if options.glossary.count > TranslationService.maximumGlossaryCharacters {
      issues.append(
        JobOptionValidationIssue(
          code: "glossary_too_large",
          message: "术语表超过 \(TranslationService.maximumGlossaryCharacters) 个字符。",
          hint: "请删除不相关术语后再试。"))
    }
    issues.append(contentsOf: ocrIssues(options, validatesOutputFormat: false))
    return issues
  }

  private static func ocrIssues(
    _ options: JobOptions, validatesOutputFormat: Bool
  ) -> [JobOptionValidationIssue] {
    var issues: [JobOptionValidationIssue] = []
    if validatesOutputFormat,
      !["searchable_pdf", "text"].contains(options.ocrOutputFormat)
    {
      issues.append(
        JobOptionValidationIssue(
          code: "invalid_ocr_output", message: "OCR 输出模式无效。",
          hint: "请重新选择可搜索 PDF 或纯文本。"))
    }
    let language = options.ocrLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    if !language.isEmpty,
      language.count > maximumOCRLanguageCharacters
        || containsControlCharacter(options.ocrLanguage)
    {
      issues.append(
        JobOptionValidationIssue(
          code: "invalid_ocr_language", message: "OCR 识别语言无效。",
          hint: "请填写 256 个字符以内的单行语言代码列表。"))
    }
    return issues
  }

  private static func languageIssue(
    _ value: String, code: String, label: String
  ) -> JobOptionValidationIssue? {
    let language = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !language.isEmpty, language.count <= maximumLanguageCharacters,
      !containsControlCharacter(value)
    else {
      return JobOptionValidationIssue(
        code: code, message: "\(label)无效。",
        hint: "请重新选择原文语言和译文语言。")
    }
    return nil
  }

  private static func containsControlCharacter(_ value: String) -> Bool {
    value.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0)
    }
  }
}

enum PDFTranslationPolicy {
  static let maximumPages = 200
  static let maximumCharacters = 200_000

  static func validate(pageCount: Int) throws {
    guard pageCount <= maximumPages else {
      throw NativeDocumentError.processingLimit(
        "PDF 翻译单次最多支持 \(maximumPages) 页；当前文档有 \(pageCount) 页。",
        recoverySuggestion: "请拆分 PDF 后分批翻译。")
    }
  }

  static func totalCharacters(afterAdding pageCharacters: Int, to currentTotal: Int) throws -> Int {
    let addition = currentTotal.addingReportingOverflow(pageCharacters)
    guard !addition.overflow, addition.partialValue <= maximumCharacters else {
      throw NativeDocumentError.processingLimit(
        "PDF 翻译单次最多支持 \(maximumCharacters.formatted()) 个待翻译字符。",
        recoverySuggestion: "请拆分 PDF 或先删除不需要翻译的页面后重试。")
    }
    return addition.partialValue
  }
}
