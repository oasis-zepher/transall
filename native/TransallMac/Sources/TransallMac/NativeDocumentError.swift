import Foundation

enum NativeDocumentError: LocalizedError {
  case invalidFile(String)
  case invalidOption(String)
  case processing(String)
  case processingLimit(String, recoverySuggestion: String)
  case provider(String)
  case layoutOverflow(Int)

  var errorDescription: String? {
    switch self {
    case .invalidFile(let message), .invalidOption(let message), .processing(let message),
      .provider(let message):
      message
    case .processingLimit(let message, _):
      message
    case .layoutOverflow(let count):
      "翻译已完成，但有 \(count) 个区域无法在可读字号下放回原位置。已保存全部译文。"
    }
  }

  var code: String {
    switch self {
    case .invalidFile: "invalid_file"
    case .invalidOption: "invalid_option"
    case .processing: "native_processing_failed"
    case .processingLimit: "processing_limit_exceeded"
    case .provider: "translation_provider_failed"
    case .layoutOverflow: "translation_layout_overflow"
    }
  }

  var recoverySuggestion: String? {
    switch self {
    case .invalidFile: "确认文件没有损坏，并与所选输入格式一致。"
    case .invalidOption: "修改任务参数后重新运行。"
    case .processing: "检查输入文件后重试；问题持续时可保留日志用于反馈。"
    case .processingLimit(_, let recoverySuggestion): recoverySuggestion
    case .provider: "检查网络、API Key、服务余额和服务商状态后重试。"
    case .layoutOverflow: "检查标记区域，或使用已保存的译文生成纯译文 PDF，无需再次调用翻译服务。"
    }
  }
}
