import Foundation

struct FormatDefinition: Codable, Equatable {
  let label: String
  let input: String
  let detail: String
}

struct CapabilityLimits: Codable, Equatable {
  let maxUploadBytes: Int
  let maxUploadMB: Int
}

enum RequirementLevel: Codable, Equatable {
  case required(Bool)
  case group(String)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(Bool.self) {
      self = .required(value)
      return
    }
    self = .group(try container.decode(String.self))
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .required(let value):
      try container.encode(value)
    case .group(let value):
      try container.encode(value)
    }
  }
}

struct RouteRequirement: Codable, Equatable, Identifiable {
  let name: String
  let required: RequirementLevel

  var id: String { name }
}

struct DependencyProfile: Codable, Equatable, Identifiable {
  let name: String
  let label: String
  let category: String
  let risk: String

  var id: String { name }
}

struct RouteDefinition: Codable, Equatable, Identifiable {
  let source: String
  let target: String
  let kind: String
  let title: String
  let enabled: Bool
  let accept: String
  let input: String
  let requirements: [RouteRequirement]
  let optionPanels: [String]
  let kindLabel: String
  let output: String
  let summary: String
  let engine: String
  let fallbackEngines: [String]
  let dependencyProfile: [DependencyProfile]
  let licenseNote: String
  let ocrFallback: Bool?

  var id: String { "\(source)->\(target)" }
}

struct CapabilitiesResponse: Codable, Equatable {
  let formats: [String: FormatDefinition]
  let routes: [RouteDefinition]
  let limits: CapabilityLimits
}

struct ProviderDefinition: Codable, Equatable, Identifiable {
  let name: String
  let baseURL: String
  let model: String
  let configured: Bool

  var id: String { name }

  enum CodingKeys: String, CodingKey {
    case name
    case baseURL = "base_url"
    case model
    case configured
  }
}

struct ProvidersResponse: Codable, Equatable {
  let providers: [ProviderDefinition]
}

struct DiagnosticDefinition: Codable, Equatable, Identifiable {
  let name: String
  let label: String
  let available: Bool
  let requiredFor: [String]
  let detail: String
  let installHint: String
  let category: String
  let risk: String
  let licenseNote: String

  var id: String { name }

  enum CodingKeys: String, CodingKey {
    case name, label, available, detail, category, risk
    case requiredFor = "required_for"
    case installHint = "install_hint"
    case licenseNote = "license_note"
  }
}

struct DiagnosticsResponse: Codable, Equatable {
  let dependencies: [DiagnosticDefinition]
}

struct PreflightIssue: Codable, Equatable, Identifiable {
  let code: String
  let dependency: String?
  let message: String
  let hint: String?

  var id: String { "\(code)-\(dependency ?? message)" }
}

struct PreflightResponse: Codable, Equatable {
  let ok: Bool
  let blockingIssues: [PreflightIssue]
  let warnings: [PreflightIssue]
  let requirements: [RouteRequirement]

  enum CodingKeys: String, CodingKey {
    case ok, warnings, requirements
    case blockingIssues = "blocking_issues"
  }
}

struct JobResponse: Codable, Equatable, Identifiable {
  let id: String
  let kind: String
  let status: String
  let inputs: [String]
  let createdAt: String
  let updatedAt: String
  let output: String?
  let error: String?
  let stage: String
  let message: String
  let errorCode: String?
  let errorHint: String?
  let retryable: Bool
  let progress: Int
  let cancelRequested: Bool
  let logs: [String]

  var isFinished: Bool { ["done", "failed", "cancelled"].contains(status) }
  var isRunning: Bool { ["queued", "running"].contains(status) }

  enum CodingKeys: String, CodingKey {
    case id, kind, status, inputs, output, error, stage, message, retryable, progress, logs
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case errorCode = "error_code"
    case errorHint = "error_hint"
    case cancelRequested = "cancel_requested"
  }
}

struct PreviewPage: Codable, Equatable, Identifiable {
  let page: Int
  let url: String

  var id: Int { page }
}

struct PreviewResponse: Codable, Equatable {
  let pages: [PreviewPage]
}

struct SelectedDocument: Identifiable, Equatable {
  let url: URL
  let size: Int64

  var id: URL { url }
  var name: String { url.lastPathComponent }

  var formattedSize: String {
    ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
  }
}

struct RouteSelection: Equatable {
  var source: String?
  var target: String?

  mutating func choose(_ format: String) {
    if source == nil || target != nil {
      source = format
      target = nil
    } else {
      target = format
    }
  }

  mutating func clear() {
    source = nil
    target = nil
  }
}

struct JobOptions {
  var provider = "deepseek"
  var outputMode = "translated"
  var sourceLanguage = "en"
  var targetLanguage = "zh"
  var glossary = ""

  var editAction = "edit"
  var deletePages = ""
  var rotatePages = ""
  var rotateDegrees = 90
  var reorderPages = ""
  var cropPages = ""
  var cropBox = ""
  var replaceFind = ""
  var replaceWith = ""
  var watermark = ""

  var ocrLanguage = "chi_sim+eng"
  var ocrOutputFormat = "searchable_pdf"

  func payload(for route: RouteDefinition) -> [String: Any] {
    switch route.kind {
    case "pdf_translate":
      return [
        "provider": provider,
        "output_mode": outputMode,
        "source_lang": sourceLanguage,
        "target_lang": targetLanguage,
        "glossary": glossary,
      ]
    case "pdf_edit":
      return [
        "action": editAction,
        "delete_pages": deletePages,
        "rotate_pages": rotatePages,
        "rotate_degrees": rotateDegrees,
        "reorder_pages": reorderPages,
        "crop_pages": cropPages,
        "crop_box": cropBox,
        "replace_find": replaceFind,
        "replace_with": replaceWith,
        "watermark": watermark,
      ]
    case "ocr":
      return [
        "language": ocrLanguage,
        "output_format": ocrOutputFormat,
      ]
    case "extract_markdown":
      return [
        "ocr_fallback": route.ocrFallback == true,
        "ocr_language": ocrLanguage,
      ]
    default:
      return [:]
    }
  }
}
