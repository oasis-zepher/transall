import AppKit
import PDFKit
import WebKit

/// An offscreen system renderer, not part of the app's navigation UI. Documents cannot
/// execute scripts or fetch external resources. Embedded images and inline CSS stay local.
@MainActor
final class WebDocumentConverter: NSObject, WKNavigationDelegate {
  private static var busy = false
  private var webView: WKWebView!
  private var window: NSWindow?
  private var navigation: CheckedContinuation<Void, Error>?
  private var printing: CheckedContinuation<Void, Error>?
  private var watchdog: Task<Void, Never>?

  static func convert(inputs: [URL], source: String, target: String, output: URL) async throws {
    while busy { try await Task.sleep(for: .milliseconds(25)) }
    try Task.checkCancellation()
    busy = true
    defer { busy = false }
    let merged = PDFDocument()
    var extracted = ""
    var total = 0
    for input in inputs {
      try Task.checkCancellation()
      let size = (try input.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max
      guard size >= 0, size <= NativeCapabilities.textToPDFLimitBytes - total else {
        throw NativeDocumentError.invalidFile("文本输入总计超过 20 MB。")
      }
      total += size
      let text = try String(contentsOf: input, encoding: .utf8)
      let body: String
      if source == "html" {
        body = text
      } else if source == "md" {
        body = try MarkdownHTML.document(text)
      } else {
        body = try MarkdownHTML.document(
          DataMarkdown.document(text, extension: input.pathExtension))
      }
      let renderer = WebDocumentConverter()
      defer { renderer.close() }
      try await renderer.load(body)
      if target == "md" {
        let markdown =
          try await renderer.webView.evaluateJavaScript(Self.markdownScript) as? String ?? ""
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw NativeDocumentError.invalidFile("\(input.lastPathComponent) 没有可提取的正文。")
        }
        if !extracted.isEmpty { extracted += "\n\n---\n\n" }
        if inputs.count > 1 {
          extracted += "# \(input.deletingPathExtension().lastPathComponent)\n\n"
        }
        extracted += markdown
        guard extracted.utf8.count <= 20 * 1_024 * 1_024 else {
          throw NativeDocumentError.processing("输出文字超过 20 MB。")
        }
      } else {
        let temporary = output.deletingLastPathComponent().appendingPathComponent(
          UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await renderer.printPDF(to: temporary)
        try Task.checkCancellation()
        guard let document = PDFDocument(url: temporary), document.pageCount > 0 else {
          throw NativeDocumentError.processing("没有生成有效 PDF。")
        }
        for index in 0..<document.pageCount {
          guard merged.pageCount < 2_000, let page = document.page(at: index)?.copy() as? PDFPage
          else {
            throw NativeDocumentError.processing("输出超过 2000 页或页面无法读取。")
          }
          merged.insert(page, at: merged.pageCount)
        }
      }
    }
    try Task.checkCancellation()
    if target == "md" {
      try extracted.write(to: output, atomically: true, encoding: .utf8)
    } else if !merged.write(to: output) {
      throw NativeDocumentError.processing("无法写入 PDF。")
    }
  }

  private func load(_ html: String) async throws {
    _ = NSApplication.shared
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let rules =
      "["
      + ["^http:", "^https:", "^file:", "^ftp:", "^ws:", "^wss:", "^blob:"].map {
        "{\"trigger\":{\"url-filter\":\"\($0)\"},\"action\":{\"type\":\"block\"}}"
      }.joined(separator: ",") + "]"
    let ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
      forIdentifier: "transall-offline-document", encodedContentRuleList: rules)
    if let ruleList { configuration.userContentController.add(ruleList) }
    webView = WKWebView(
      frame: NSRect(x: 0, y: 0, width: 710, height: 950), configuration: configuration)
    webView.navigationDelegate = self
    window = NSWindow(
      contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window?.isReleasedWhenClosed = false
    window?.contentView = webView
    let shell = """
      <!doctype html><html><head><meta charset="utf-8">
      <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
      <style>html{color:#161616;background:white;font:14px -apple-system,BlinkMacSystemFont,sans-serif;line-height:1.5}body{margin:0;overflow-wrap:anywhere}img{max-width:100%;height:auto}table{border-collapse:collapse;width:100%;max-width:100%}td,th{border:1px solid #aaa;padding:6px}pre{white-space:pre-wrap;overflow-wrap:anywhere}tr,img,pre{break-inside:avoid}h1,h2,h3{break-after:avoid}blockquote{border-left:3px solid #aaa;padding-left:12px}a{color:inherit}</style></head><body>\(html)</body></html>
      """
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        navigation = continuation
        watchdog = Task { [weak self] in
          do { try await Task.sleep(for: .seconds(30)) } catch { return }
          self?.finishLoad(.failure(NativeDocumentError.processing("文档排版超时。")))
        }
        webView.loadHTMLString(shell, baseURL: nil)
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.finishLoad(.failure(CancellationError())) }
    }
    try Task.checkCancellation()
  }

  private func finishLoad(_ result: Swift.Result<Void, Error>) {
    guard let pending = navigation else { return }
    navigation = nil
    watchdog?.cancel()
    watchdog = nil
    if case .failure = result { webView?.stopLoading() }
    pending.resume(with: result)
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    finishLoad(.success(()))
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    finishLoad(.failure(error))
  }
  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) { finishLoad(.failure(error)) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    finishLoad(.failure(NativeDocumentError.processing("文档排版进程已退出。")))
  }
  func webView(
    _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
    decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
  ) {
    decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
  }

  private func printPDF(to url: URL) async throws {
    try Task.checkCancellation()
    // Wait for embedded image decoding before AppKit lays out printable pages.
    _ = try await webView.callAsyncJavaScript(
      "await Promise.all(Array.from(document.images).map(i => i.decode().catch(() => {}))); return true;",
      arguments: [:], in: nil, contentWorld: .defaultClient)
    let height =
      try await webView.evaluateJavaScript("document.documentElement.scrollHeight") as? Double ?? 0
    guard height.isFinite, height <= 1_500_000 else {
      throw NativeDocumentError.processing("排版内容过长，请拆分文件后重试。")
    }
    let info = NSPrintInfo()
    info.paperSize = NSSize(width: 595, height: 842)
    info.topMargin = 42
    info.bottomMargin = 42
    info.leftMargin = 42
    info.rightMargin = 42
    info.horizontalPagination = .fit
    info.isHorizontallyCentered = false
    info.isVerticallyCentered = false
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
    let operation = webView.printOperation(with: info)
    operation.showsPrintPanel = false
    operation.showsProgressPanel = false
    guard let window else { throw NativeDocumentError.processing("无法创建排版窗口。") }
    try await withCheckedThrowingContinuation { continuation in
      printing = continuation
      operation.runModal(
        for: window, delegate: self, didRun: #selector(printFinished(_:success:context:)),
        contextInfo: nil)
    }
    try Task.checkCancellation()
  }
  @objc private func printFinished(
    _ operation: NSPrintOperation, success: Bool, context: UnsafeMutableRawPointer?
  ) {
    let pending = printing
    printing = nil
    if success {
      pending?.resume()
    } else {
      pending?.resume(throwing: NativeDocumentError.processing("PDF 排版未完成。"))
    }
  }
  private func close() {
    watchdog?.cancel()
    webView?.stopLoading()
    webView?.navigationDelegate = nil
    window?.contentView = nil
    window?.close()
    window = nil
    webView = nil
  }

  static let markdownScript = #"""
    (() => {
      let visited = 0;
      const inline = n => {
        if (++visited > 250000) throw Error('Document too large');
        if (n.nodeType === 3) return n.textContent.replace(/([\\`*_[\]])/g, '\\$1');
        if (n.nodeType !== 1) return '';
        const tag = n.tagName.toLowerCase();
        if (['script','style','noscript','iframe','object','head','svg'].includes(tag) || n.hidden) return '';
        const text = () => Array.from(n.childNodes).map(inline).join('');
        if (/^h[1-6]$/.test(tag)) return '\n\n' + '#'.repeat(+tag[1]) + ' ' + text().trim() + '\n\n';
        if (tag === 'br') return '\n';
        if (tag === 'hr') return '\n\n---\n\n';
        if (tag === 'pre') { const fence = '`'.repeat(Math.max(3, ...Array.from(n.textContent.matchAll(/`+/g), m => m[0].length + 1))); return '\n\n' + fence + '\n' + n.textContent + '\n' + fence + '\n\n'; }
        if (tag === 'code') return '`' + n.textContent.replace(/`/g, '\\`') + '`';
        if (tag === 'b' || tag === 'strong') return '**' + text() + '**';
        if (tag === 'i' || tag === 'em') return '*' + text() + '*';
        if (tag === 'a') { const href = n.getAttribute('href') || ''; return /^(https?:|mailto:|#)/i.test(href) ? '[' + text() + '](' + href.replace(/\)/g,'%29') + ')' : text(); }
        if (tag === 'img') return '[图片：' + (n.getAttribute('alt') || '未提供替代文字') + ']';
        if (tag === 'li') return '\n' + (n.parentElement?.tagName === 'OL' ? '1. ' : '- ') + text().trim();
        if (tag === 'blockquote') return '\n\n' + text().trim().split('\n').map(l => '> ' + l).join('\n') + '\n\n';
        if (tag === 'table') {
          const rows = Array.from(n.rows).map(r => Array.from(r.cells).map(c => inline(c).trim().replace(/\n+/g,' ').replace(/\|/g,'\\|')));
          const width = Math.max(0,...rows.map(r => r.length)); if (!width) return '';
          const lines = rows.map(r => '| ' + r.concat(Array(width-r.length).fill('')).join(' | ') + ' |');
          lines.splice(1,0,'| ' + Array(width).fill('---').join(' | ') + ' |'); return '\n\n' + lines.join('\n') + '\n\n';
        }
        if (['p','div','section','article','ul','ol'].includes(tag)) return '\n\n' + text() + '\n\n';
        return text();
      };
      return inline(document.body).replace(/\n[ \t]+/g,'\n').replace(/\n{3,}/g,'\n\n').trim() + '\n';
    })()
    """#
}

enum MarkdownHTML {
  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
  }
  static func document(_ text: String) throws -> String {
    let parsed = try AttributedString(markdown: text, options: .init(interpretedSyntax: .full))
    var ancestry: [PresentationIntent.IntentType] = []
    var output = ""
    for run in parsed.runs {
      try Task.checkCancellation()
      let intents = Array(
        (run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]?.components
          ?? []).reversed())
      let common = zip(ancestry, intents).prefix { $0.identity == $1.identity }.count
      for old in ancestry.dropFirst(common).reversed() { output += tags(old).1 }
      for new in intents.dropFirst(common) { output += tags(new).0 }
      ancestry = intents
      var value = escape(String(parsed[run.range].characters))
      let inline =
        run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] ?? []
      if let image = run[AttributeScopes.FoundationAttributes.ImageURLAttribute.self] {
        let url = image.absoluteString
        value =
          url.lowercased().hasPrefix("data:image/")
          ? "<img src=\"\(escape(url))\" alt=\"\(value)\">" : "[图片：\(value)]"
      } else {
        if inline.contains(.code) { value = "<code>\(value)</code>" }
        if inline.contains(.stronglyEmphasized) { value = "<strong>\(value)</strong>" }
        if inline.contains(.emphasized) { value = "<em>\(value)</em>" }
        if inline.contains(.strikethrough) { value = "<del>\(value)</del>" }
        if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self],
          ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "")
        {
          value = "<a href=\"\(escape(link.absoluteString))\">\(value)</a>"
        }
      }
      output += value
    }
    for old in ancestry.reversed() { output += tags(old).1 }
    return output
  }
  private static func tags(_ intent: PresentationIntent.IntentType) -> (String, String) {
    switch intent.kind {
    case .paragraph: ("<p>", "</p>")
    case .header(let level): ("<h\(level)>", "</h\(level)>")
    case .orderedList: ("<ol>", "</ol>")
    case .unorderedList: ("<ul>", "</ul>")
    case .listItem: ("<li>", "</li>")
    case .codeBlock: ("<pre>", "</pre>")
    case .blockQuote: ("<blockquote>", "</blockquote>")
    case .table: ("<table>", "</table>")
    case .tableHeaderRow, .tableRow: ("<tr>", "</tr>")
    case .tableCell: ("<td>", "</td>")
    case .thematicBreak: ("<hr>", "")
    @unknown default: ("<div>", "</div>")
    }
  }
}

enum DataMarkdown {
  static func document(_ text: String, extension suffix: String) throws -> String {
    if ["csv", "tsv"].contains(suffix.lowercased()) {
      var rows: [[String]] = []
      var row: [String] = []
      var cell = ""
      var quoted = false
      let characters = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
      var i = 0
      let separator: Character = suffix.lowercased() == "tsv" ? "\t" : ","
      while i < characters.count {
        let char = characters[i]
        if char == "\"" {
          if quoted && i + 1 < characters.count && characters[i + 1] == "\"" {
            cell.append("\"")
            i += 1
          } else {
            quoted.toggle()
          }
        } else if char == separator && !quoted {
          row.append(cell)
          cell = ""
        } else if (char == "\n" || char == "\r") && !quoted {
          row.append(cell)
          rows.append(row)
          row = []
          cell = ""
          if char == "\r" && i + 1 < characters.count && characters[i + 1] == "\n" { i += 1 }
        } else {
          cell.append(char)
        }
        guard row.count <= 128, rows.count <= 20_000 else {
          throw NativeDocumentError.processing("数据表格过大，请拆分文件。")
        }
        i += 1
      }
      guard !quoted else { throw NativeDocumentError.invalidFile("CSV 引号未闭合。") }
      if !cell.isEmpty || !row.isEmpty {
        row.append(cell)
        rows.append(row)
      }
      let columns = rows.map(\.count).max() ?? 0
      guard columns > 0 else { throw NativeDocumentError.invalidFile("数据表为空。") }
      var lines = rows.map { row in
        "| "
          + (row + Array(repeating: "", count: columns - row.count)).map {
            $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(
              of: "\n", with: "<br>")
          }.joined(separator: " | ") + " |"
      }
      lines.insert(
        "| " + Array(repeating: "---", count: columns).joined(separator: " | ") + " |", at: 1)
      return lines.joined(separator: "\n") + "\n"
    }
    var content = text
    if suffix.lowercased() == "json" {
      let value = try JSONSerialization.jsonObject(
        with: Data(text.utf8), options: .fragmentsAllowed)
      content = String(
        decoding: try JSONSerialization.data(
          withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
        as: UTF8.self)
    }
    let fence = String(
      repeating: "`",
      count: max(3, (content.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1))
    let language =
      ["json", "xml", "yaml", "yml"].contains(suffix.lowercased()) ? suffix.lowercased() : "text"
    return "\(fence)\(language)\n\(content)\n\(fence)\n"
  }
}
