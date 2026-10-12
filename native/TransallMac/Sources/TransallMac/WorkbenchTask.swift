import UniformTypeIdentifiers

enum WorkbenchTask: String, CaseIterable, Identifiable {
  case editPDF, translatePDF, recognizeText, extractMarkdown, createPDF

  var id: Self { self }
  var title: String {
    switch self {
    case .editPDF: "整理 PDF"
    case .translatePDF: "翻译 PDF"
    case .recognizeText: "识别文字"
    case .extractMarkdown: "提取 Markdown"
    case .createPDF: "生成 PDF"
    }
  }
  var symbol: String {
    switch self {
    case .editPDF: "doc.on.doc"
    case .translatePDF: "character.bubble"
    case .recognizeText: "text.viewfinder"
    case .extractMarkdown: "text.document"
    case .createPDF: "doc.badge.plus"
    }
  }
  var sources: [String] {
    switch self {
    case .editPDF, .translatePDF: ["pdf"]
    case .recognizeText: ["pdf", "image"]
    case .extractMarkdown: ["pdf", "image", "word", "ppt", "excel", "html", "data"]
    case .createPDF: ["image", "word", "ppt", "excel", "md", "html", "data"]
    }
  }
  var target: String {
    switch self {
    case .editPDF, .createPDF: "pdf"
    case .translatePDF: "translated_pdf"
    case .recognizeText: "ocr"
    case .extractMarkdown: "md"
    }
  }
  func selection(source: String? = nil) -> RouteSelection {
    RouteSelection(
      source: source.flatMap { sources.contains($0) ? $0 : nil } ?? sources[0], target: target)
  }
  static func matching(_ selection: RouteSelection) -> Self? {
    allCases.first { $0.target == selection.target && $0.sources.contains(selection.source ?? "") }
  }
  static func sourceTitle(_ source: String) -> String {
    switch source {
    case "word": "Word"
    case "ppt": "PPT"
    case "excel": "Excel"
    case "pdf": "PDF"
    case "image": "图片"
    case "md": "Markdown"
    case "html": "HTML"
    case "data": "文本数据"
    default: source
    }
  }
  static func contentTypes(source: String?) -> [UTType] {
    // The importer is created before a saved route is restored. An empty initial
    // type list can leave AppKit's restored panel unable to select any document.
    let routes = NativeCapabilities.routes.filter { source == nil || $0.source == source }
    let extensions = Set(
      routes.flatMap { route in
        route.accept.split(separator: ",").map {
          $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
        }
      })
    let types = extensions.sorted().compactMap { UTType(filenameExtension: $0) }
    return types.isEmpty ? [.item] : types
  }
}
