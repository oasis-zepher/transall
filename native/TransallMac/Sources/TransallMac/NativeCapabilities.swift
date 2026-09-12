import Foundation

enum NativeCapabilities {
  static let uploadLimitBytes = 250 * 1024 * 1024
  static let textToPDFLimitBytes = 20 * 1024 * 1024
  static let textToPDFLimitMB = 20
  static let maximumInputFileCount = 256

  static let response = CapabilitiesResponse(
    formats: [
      "pdf": FormatDefinition(label: "PDF", input: ".pdf", detail: "PDF 文档"),
      "word": FormatDefinition(label: "Word", input: ".doc,.docx", detail: "Word 文档"),
      "translated_pdf": FormatDefinition(
        label: "译文 PDF", input: ".pdf", detail: "翻译后的 PDF"),
      "ocr": FormatDefinition(
        label: "OCR", input: ".pdf,.png,.jpg,.jpeg,.tiff,.heic", detail: "文字识别"),
      "ppt": FormatDefinition(label: "PPT", input: ".ppt,.pptx", detail: "演示文稿"),
      "excel": FormatDefinition(label: "Excel", input: ".xls,.xlsx", detail: "电子表格"),
      "md": FormatDefinition(label: "Markdown", input: ".md,.markdown,.txt", detail: "Markdown 文本"),
      "html": FormatDefinition(label: "HTML", input: ".html,.htm", detail: "网页文档"),
      "image": FormatDefinition(
        label: "图片", input: ".png,.jpg,.jpeg,.webp,.tif,.tiff,.heic", detail: "常见图片"),
      "data": FormatDefinition(
        label: "数据", input: ".txt,.text,.csv,.tsv,.json,.xml,.yaml,.yml", detail: "文本数据"),
    ],
    routes: routes,
    limits: CapabilityLimits(maxUploadBytes: uploadLimitBytes, maxUploadMB: 250)
  )

  static let routes: [RouteDefinition] = [
    route(
      "word", "pdf", "office_convert", "Word 转 PDF", "生成 PDF", "Word", "PDF 文档",
      "在本机转换，保留原文件。", "LibreOffice",
      requirements: [RouteRequirement(name: "libreoffice", required: .required(true))]),
    route(
      "word", "md", "office_convert", "Word 转 Markdown", "提取 Markdown", "Word", "Markdown",
      "在本机转换，保留原文件。", "LibreOffice",
      requirements: [RouteRequirement(name: "libreoffice", required: .required(true))]),
    route(
      "ppt", "pdf", "office_convert", "PPT 转 PDF", "生成 PDF", "PPT", "PDF 文档",
      "在本机转换，保留原文件。", "LibreOffice",
      requirements: [RouteRequirement(name: "libreoffice", required: .required(true))]),
    route(
      "ppt", "md", "office_convert", "PPT 转 Markdown", "提取 Markdown", "PPT", "Markdown",
      "在本机转换，保留原文件。", "LibreOffice",
      requirements: [RouteRequirement(name: "libreoffice", required: .required(true))]),
    route(
      "excel", "pdf", "office_convert", "Excel 转 PDF", "生成 PDF", "Excel", "PDF 文档",
      "在本机转换，保留原文件。", "LibreOffice",
      requirements: [RouteRequirement(name: "libreoffice", required: .required(true))]),
    route(
      "excel", "md", "office_convert", "Excel 转 Markdown", "提取 Markdown", "Excel", "Markdown",
      "在本机转换，保留原文件。", "LibreOffice",
      requirements: [RouteRequirement(name: "libreoffice", required: .required(true))]),
    route(
      "html", "md", "extract_markdown", "HTML 转 Markdown", "提取 Markdown", "HTML", "Markdown",
      "在本机转换，保留原文件。", "WebKit / Foundation"),
    route(
      "data", "md", "extract_markdown", "文本数据 转 Markdown", "提取 Markdown", "文本数据", "Markdown",
      "在本机转换，保留原文件。", "WebKit / Foundation"),
    route(
      "pdf", "pdf", "pdf_edit", "整理 PDF", "PDF 编辑", "PDF 文档", "PDF 文档",
      "使用 PDFKit 合并、删除、旋转、重排、裁剪和添加水印。", "PDFKit / Core Graphics",
      panels: ["edit", "advanced"]),
    route(
      "pdf", "translated_pdf", "pdf_translate", "翻译 PDF", "PDF 翻译", "PDF 文档", "译文 PDF",
      "先在本机提取并检查全文，再通过所选服务翻译；处理过程不修改原文件。", "PDFKit / URLSession",
      requirements: [RouteRequirement(name: "deepseek", required: .required(true))],
      panels: ["translate", "advanced"]),
    route(
      "pdf", "ocr", "ocr", "识别 PDF", "OCR", "PDF 文档", "可搜索 PDF 或文本",
      "使用 Apple Vision 在本机识别文字。", "Vision / Core Graphics", panels: ["ocr", "advanced"]),
    route(
      "image", "ocr", "ocr", "识别图片", "OCR", "图片", "可搜索 PDF 或文本",
      "使用 Apple Vision 在本机识别文字。", "Vision / Core Graphics", panels: ["ocr", "advanced"]),
    route(
      "pdf", "md", "extract_markdown", "提取 PDF 文字", "提取 Markdown", "PDF 文档", "Markdown",
      "优先提取 PDF 文字层；扫描页可使用 Vision 识别。", "PDFKit / Vision", panels: ["ocr", "advanced"],
      ocrFallback: true),
    route(
      "image", "md", "extract_markdown", "图片转 Markdown", "提取 Markdown", "图片", "Markdown",
      "使用 Apple Vision 在本机识别图片文字。", "Vision", panels: ["ocr", "advanced"],
      ocrFallback: true),
    route(
      "image", "pdf", "image_to_pdf", "图片合成 PDF", "生成 PDF", "图片", "PDF 文档",
      "按文件顺序将图片写入一个 PDF。", "Core Graphics"),
    route(
      "md", "pdf", "text_to_pdf", "Markdown 转 PDF", "生成 PDF", "Markdown 文本", "PDF 文档",
      "排版标题、列表、表格、代码和内嵌图片，生成可搜索 PDF。", "WebKit / AppKit"),
    route(
      "html", "pdf", "text_to_pdf", "HTML 转 PDF", "生成 PDF", "HTML 文档", "PDF 文档",
      "保留 HTML 样式、表格与内嵌图片，生成 PDF。", "WebKit / AppKit"),
    route(
      "data", "pdf", "text_to_pdf", "文本数据转 PDF", "生成 PDF", "文本数据", "PDF 文档",
      "将 TXT、CSV 或 JSON 使用原生排版生成 PDF。", "Core Text / Core Graphics"),
  ]

  static func inputLimitBytes(for route: RouteDefinition) -> Int {
    ["text_to_pdf", "extract_markdown"].contains(route.kind)
      && ["md", "html", "data"].contains(route.source) ? textToPDFLimitBytes : uploadLimitBytes
  }

  static func inputLimitMB(for route: RouteDefinition) -> Int {
    ["text_to_pdf", "extract_markdown"].contains(route.kind)
      && ["md", "html", "data"].contains(route.source)
      ? textToPDFLimitMB : response.limits.maxUploadMB
  }

  static func diagnostics(providerConfigured: [ProviderCredential: Bool]) -> DiagnosticsResponse {
    DiagnosticsResponse(dependencies: [
      DiagnosticDefinition(
        name: "pdfkit", label: "Apple PDFKit", available: true,
        requiredFor: ["PDF 编辑", "PDF 翻译", "PDF 预览"], detail: "随 macOS 提供。", installHint: "",
        category: "system_framework", risk: "low", licenseNote: "Apple system framework"),
      DiagnosticDefinition(
        name: "vision", label: "Apple Vision", available: true,
        requiredFor: ["OCR", "扫描 PDF 文字提取"], detail: "识别在本机完成。", installHint: "",
        category: "system_framework", risk: "low", licenseNote: "Apple system framework"),
      DiagnosticDefinition(
        name: "libreoffice", label: "Office 文档转换",
        available: OfficeDocumentConverter.executable != nil
          && !OfficeConversionComponent.requiresSetup,
        requiredFor: ["Office 转 PDF", "Office 转 Markdown"],
        detail: OfficeDocumentConverter.executable == nil
          ? OfficeDocumentConverter.missingMessage : "已检测到 LibreOffice，转换在本机完成。",
        installHint: OfficeDocumentConverter.missingMessage, category: "local_application",
        risk: "local_processing", licenseNote: "LibreOffice 由用户单独安装。"),
      providerDiagnostic(.deepseek, configured: providerConfigured[.deepseek] == true),
      providerDiagnostic(.openAI, configured: providerConfigured[.openAI] == true),
    ])
  }

  static func providers(configured: [ProviderCredential: Bool]) -> ProvidersResponse {
    ProvidersResponse(providers: [
      ProviderDefinition(
        name: "deepseek", baseURL: "https://api.deepseek.com", model: "deepseek-chat",
        configured: configured[.deepseek] == true),
      ProviderDefinition(
        name: "openai", baseURL: "https://api.openai.com/v1", model: "gpt-4o-mini",
        configured: configured[.openAI] == true),
    ])
  }

  private static func route(
    _ source: String, _ target: String, _ kind: String, _ title: String, _ kindLabel: String,
    _ input: String, _ output: String, _ summary: String, _ engine: String,
    requirements: [RouteRequirement] = [], panels: [String] = [], ocrFallback: Bool? = nil
  ) -> RouteDefinition {
    RouteDefinition(
      source: source, target: target, kind: kind, title: title, enabled: true,
      accept: responseAccept(for: source), input: input, requirements: requirements,
      optionPanels: panels, kindLabel: kindLabel, output: output, summary: summary, engine: engine,
      fallbackEngines: [], dependencyProfile: [],
      licenseNote: engine == "LibreOffice" ? "使用独立安装的 LibreOffice。" : "使用 macOS 系统框架。",
      ocrFallback: ocrFallback)
  }

  private static func responseAccept(for source: String) -> String {
    switch source {
    case "word": ".doc, .docx"
    case "ppt": ".ppt, .pptx"
    case "excel": ".xls, .xlsx"
    case "pdf": ".pdf"
    case "image": ".png, .jpg, .jpeg, .webp, .tif, .tiff, .heic"
    case "md": ".md, .markdown, .txt"
    case "html": ".html, .htm"
    case "data": ".txt, .text, .csv, .tsv, .json, .xml, .yaml, .yml"
    default: ""
    }
  }

  private static func providerDiagnostic(
    _ credential: ProviderCredential, configured: Bool
  ) -> DiagnosticDefinition {
    let label = credential == .deepseek ? "DeepSeek" : "OpenAI"
    return DiagnosticDefinition(
      name: credential.rawValue, label: label, available: configured,
      requiredFor: ["PDF 翻译"], detail: configured ? "API Key 已保存在钥匙串。" : "尚未配置 API Key。",
      installHint: configured ? "" : "在 Transall 设置中填写 API Key。", category: "network_provider",
      risk: "remote_content_processing", licenseNote: "文档文字会发送给所选服务商。")
  }
}
