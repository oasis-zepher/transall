import Foundation

enum OutputFileNamer {
  static func name(
    for route: RouteDefinition, options: JobOptions, inputNames: [String]
  ) -> String {
    let firstName = inputNames.first.map(originalInputName) ?? "document"
    let stem = safeOutputStem(
      URL(fileURLWithPath: firstName).deletingPathExtension().lastPathComponent)
    return switch route.kind {
    case "pdf_edit" where options.editAction == "merge": "merged.pdf"
    case "pdf_edit": "\(stem)-edited.pdf"
    case "ocr" where options.ocrOutputFormat == "text": "\(stem)-ocr.txt"
    case "ocr": "\(stem)-ocr.pdf"
    case "office_convert" where route.target == "md": "\(stem).md"
    case "extract_markdown": "\(stem).md"
    case "pdf_translate" where options.outputMode == "bilingual": "\(stem)-bilingual.pdf"
    case "pdf_translate": "\(stem)-translated.pdf"
    case "image_to_pdf" where inputNames.count > 1: "images.pdf"
    default: "\(stem).pdf"
    }
  }

  private static func originalInputName(_ value: String) -> String {
    value.replacingOccurrences(
      of: #"^\d+-"#, with: "", options: .regularExpression)
  }

  private static func safeOutputStem(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
    let filtered = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
    let result = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
    return String((result.isEmpty ? "document" : result).prefix(80))
  }
}
