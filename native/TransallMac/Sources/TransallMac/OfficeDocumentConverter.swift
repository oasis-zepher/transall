import AppKit
import Darwin
import Foundation
import PDFKit

/// Optional local Office conversion. Each request has its own profile and temporary files.
enum OfficeDocumentConverter {
  static var executable: URL? {
    [
      URL(fileURLWithPath: "/Applications/LibreOffice.app/Contents/MacOS/soffice"),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Applications/LibreOffice.app/Contents/MacOS/soffice"),
    ]
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  static let missingMessage = "Office 转换需要 LibreOffice。安装到“应用程序”后即可使用，无需配置。"

  static func convert(inputs: [URL], source: String, target: String, output: URL) async throws {
    guard let executable else { throw NativeDocumentError.processing(missingMessage) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pdf = PDFDocument()
    var markdown = ""
    for (index, input) in inputs.enumerated() {
      try Task.checkCancellation()
      let work = directory.appendingPathComponent(String(index))
      try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
      let staged = work.appendingPathComponent("input")
      try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
      let localInput = staged.appendingPathComponent(input.lastPathComponent)
      try FileManager.default.copyItem(at: input, to: localInput)
      let profile = work.appendingPathComponent("profile/user")
      try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
      let policy = """
        <?xml version="1.0" encoding="UTF-8"?><oor:items xmlns:oor="http://openoffice.org/2001/registry">
        <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
        </oor:items>
        """
      try policy.write(
        to: profile.appendingPathComponent("registrymodifications.xcu"), atomically: true,
        encoding: .utf8)
      let format =
        target == "pdf" ? "pdf" : (source == "word" ? "fodt" : source == "ppt" ? "fodp" : "fods")
      _ = try await OfficeConversionComponent.run(
        executable: executable,
        arguments: [
          "-env:UserInstallation=\(work.appendingPathComponent("profile").absoluteString)",
          "--headless", "--nologo", "--nodefault", "--norestore", "--convert-to", format,
          "--outdir", work.path, localInput.path,
        ], directory: work)
      let result = work.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
        .appendingPathExtension(format)
      guard FileManager.default.fileExists(atPath: result.path) else {
        throw NativeDocumentError.processing("无法转换 \(input.lastPathComponent)。请确认文件未加密且可正常打开。")
      }
      if target == "pdf" {
        guard let document = PDFDocument(url: result), !document.isLocked, document.pageCount > 0
        else {
          throw NativeDocumentError.processing("Office 转换没有生成有效 PDF。")
        }
        for pageIndex in 0..<document.pageCount {
          try Task.checkCancellation()
          guard pdf.pageCount < 2_000, let page = document.page(at: pageIndex)?.copy() as? PDFPage
          else {
            throw NativeDocumentError.processing("Office 输出页数过多或页面无法读取。")
          }
          pdf.insert(page, at: pdf.pageCount)
        }
      } else {
        let text = try OpenDocumentMarkdown.read(result)
        if !markdown.isEmpty { markdown += "\n\n---\n\n" }
        if inputs.count > 1 {
          markdown += "# \(input.deletingPathExtension().lastPathComponent)\n\n"
        }
        markdown += text
        guard markdown.utf8.count <= 20 * 1_024 * 1_024 else {
          throw NativeDocumentError.processing("提取文字超过 20 MB，请拆分文件。")
        }
      }
    }
    try Task.checkCancellation()
    if target == "pdf" {
      guard pdf.write(to: output) else { throw NativeDocumentError.processing("无法保存 Office PDF。") }
    } else {
      try markdown.write(to: output, atomically: true, encoding: .utf8)
    }
  }
}

/// No shell interpolation; bounded output, timeout, and cancellation terminate the child.
@MainActor
enum LocalConversionProcess {
  static func run(
    _ executable: URL, arguments: [String], directory: URL, timeout: TimeInterval = 120,
    maximumOutput: Int = 1_024 * 1_024
  ) async throws -> Data {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    // AppKit helpers must register as themselves, not inherit the launching app's identity.
    var environment = ProcessInfo.processInfo.environment
    for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS"] {
      environment.removeValue(forKey: key)
    }
    process.environment = environment
    process.currentDirectoryURL = directory
    let log = directory.appendingPathComponent(UUID().uuidString + ".log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: log)
    }
    process.standardOutput = handle
    process.standardError = handle
    process.standardInput = FileHandle.nullDevice
    try Task.checkCancellation()
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    do {
      while process.isRunning {
        try Task.checkCancellation()
        guard Date() < deadline else { throw NativeDocumentError.processing("文档转换超时，请拆分文件后重试。") }
        let bytes = (try log.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard bytes <= maximumOutput else { throw NativeDocumentError.processing("转换输出异常，任务已停止。") }
        try await Task.sleep(for: .milliseconds(50))
      }
      try Task.checkCancellation()
    } catch {
      if process.isRunning { process.terminate() }
      // Reap before deleting the private profile. SIGKILL bounds a non-cooperative child.
      for _ in 0..<20 where process.isRunning {
        try? await Task.sleep(for: .milliseconds(25))
      }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw error
    }
    process.waitUntilExit()
    let size = (try log.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
    guard size <= maximumOutput else { throw NativeDocumentError.processing("转换输出超过限制。") }
    let data = try Data(contentsOf: log)
    guard process.terminationStatus == 0 else {
      throw NativeDocumentError.processing("本地文档转换失败。请确认 LibreOffice 能正常打开此文件。")
    }
    return data
  }
}

private final class ODFNode {
  let name: String
  let attributes: [String: String]
  var children: [ODFNode] = []
  var text = ""
  init(_ name: String, _ attributes: [String: String] = [:]) {
    self.name = name
    self.attributes = attributes
  }
  var content: String {
    if name == "text:s" {
      return String(repeating: " ", count: min(1000, max(1, Int(attributes["text:c"] ?? "1") ?? 1)))
    }
    if name == "text:tab" { return "\t" }
    if name == "text:line-break" { return "\n" }
    return text + children.map(\.content).joined()
  }
}

private final class ODFReader: NSObject, XMLParserDelegate {
  let root = ODFNode("root")
  var stack: [ODFNode] = []
  var count = 0
  var characters = 0
  var failure: Error?
  override init() {
    super.init()
    stack = [root]
  }
  func parser(
    _ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    count += 1
    if count > 250_000 || stack.count > 128 || Task.isCancelled {
      failure = Task.isCancelled ? CancellationError() : NativeDocumentError.processing("文档结构过大。")
      parser.abortParsing()
      return
    }
    let node = ODFNode(element, attributes)
    stack.last?.children.append(node)
    stack.append(node)
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard stack.last?.name != "office:binary-data" else { return }
    characters += string.utf8.count
    if characters > 20 * 1_024 * 1_024 {
      failure = NativeDocumentError.processing("文档文字超过 20 MB。")
      parser.abortParsing()
      return
    }
    // Text nodes preserve ordering around inline spans.
    let node = ODFNode("#text")
    node.text = string
    stack.last?.children.append(node)
  }
  func parser(
    _ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?
  ) { if stack.count > 1 { stack.removeLast() } }
}

enum OpenDocumentMarkdown {
  static func read(_ url: URL) throws -> String {
    let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
    guard size <= 100 * 1_024 * 1_024, let parser = XMLParser(contentsOf: url) else {
      throw NativeDocumentError.processing("Office 文档展开后超过 100 MB，请拆分文件。")
    }
    let reader = ODFReader()
    parser.shouldResolveExternalEntities = false
    parser.delegate = reader
    guard parser.parse() else {
      throw reader.failure ?? NativeDocumentError.invalidFile("无法读取 Office 文档结构。")
    }
    guard
      let body = reader.root.children.flatMap(\.children).first(where: { $0.name == "office:body" })
    else {
      throw NativeDocumentError.invalidFile("Office 文档缺少正文。")
    }
    let text = try render(body).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw NativeDocumentError.invalidFile("文档中没有可提取的文字。") }
    return text + "\n"
  }
  private static func render(_ node: ODFNode) throws -> String {
    switch node.name {
    case "office:styles", "office:automatic-styles", "office:meta", "office:settings",
      "office:binary-data":
      return ""
    case "text:h":
      return String(
        repeating: "#",
        count: min(6, max(1, Int(node.attributes["text:outline-level"] ?? "1") ?? 1))) + " "
        + node.content + "\n\n"
    case "text:p": return node.content + "\n\n"
    case "text:list-item":
      return "- "
        + (try node.children.map { try render($0) }.joined()).trimmingCharacters(
          in: .whitespacesAndNewlines) + "\n"
    case "draw:page":
      return "## " + (node.attributes["draw:name"] ?? "幻灯片") + "\n\n"
        + (try node.children.map { try render($0) }.joined())
    case "table:table":
      let rows = node.children.flatMap { child -> [ODFNode] in
        child.name == "table:table-row"
          ? [child] : child.children.filter { $0.name == "table:table-row" }
      }
      guard rows.count <= 10_000 else {
        throw NativeDocumentError.processing("表格超过 10000 行，请拆分文件。")
      }
      var values: [[String]] = []
      for row in rows {
        var cells: [String] = []
        var column = 0
        for cell in row.children
        where cell.name == "table:table-cell" || cell.name == "table:covered-table-cell" {
          var value = cell.content.trimmingCharacters(in: .whitespacesAndNewlines)
          if value.isEmpty {
            value = cell.attributes["office:value"] ?? cell.attributes["office:string-value"] ?? ""
          }
          value = value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(
            of: "\n", with: " ")
          let repeats = min(
            129, max(1, Int(cell.attributes["table:number-columns-repeated"] ?? "1") ?? 1))
          if !value.isEmpty {
            guard column + repeats <= 128 else {
              throw NativeDocumentError.processing("表格超过 128 列，请拆分文件。")
            }
            cells += Array(repeating: "", count: column - cells.count)
            cells += Array(repeating: value, count: repeats)
          }
          column = min(129, column + repeats)
        }
        if !cells.isEmpty {
          let repeats = max(1, Int(row.attributes["table:number-rows-repeated"] ?? "1") ?? 1)
          guard repeats <= 10_000 - values.count else {
            throw NativeDocumentError.processing("表格超过 10000 行，请拆分文件。")
          }
          values += Array(repeating: cells, count: repeats)
        }
      }
      let columns = values.map(\.count).max() ?? 0
      guard columns > 0 else { return "" }
      let lines = values.map {
        "| " + ($0 + Array(repeating: "", count: columns - $0.count)).joined(separator: " | ")
          + " |"
      }
      return (node.attributes["table:name"].map { "## \($0)\n\n" } ?? "")
        + ([
          lines[0], "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |",
        ] + lines.dropFirst()).joined(separator: "\n") + "\n\n"
    default: return try node.children.map { try render($0) }.joined()
    }
  }
}
