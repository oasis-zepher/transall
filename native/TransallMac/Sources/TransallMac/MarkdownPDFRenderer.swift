import AppKit
import CoreGraphics
import CoreText
import Foundation

/// Uses Foundation's Markdown parser, then lays out semantic blocks with Core Text.
/// No HTML execution, remote image loading, or browser process is involved.
enum MarkdownPDFRenderer {
  struct Block {
    let identity: Int
    let intents: [PresentationIntent.IntentType]
    let text: NSMutableAttributedString

    var table: (id: Int, columns: [PresentationIntent.TableColumn])? {
      for intent in intents {
        if case .table(let columns) = intent.kind { return (intent.identity, columns) }
      }
      return nil
    }

    var rowIdentity: Int? {
      intents.first {
        switch $0.kind {
        case .tableHeaderRow, .tableRow: true
        default: false
        }
      }?.identity
    }

    var isTableHeader: Bool { intents.contains { $0.kind == .tableHeaderRow } }
  }

  static func blocks(_ markdown: String) throws -> [Block] {
    let parsed = try AttributedString(
      markdown: markdown,
      options: .init(interpretedSyntax: .full, failurePolicy: .throwError))
    var result: [Block] = []
    for run in parsed.runs {
      try Task.checkCancellation()
      let intents =
        run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]?.components ?? []
      let identity = intents.first?.identity ?? 0
      if result.last?.identity != identity {
        guard result.count < 25_000 else {
          throw NativeDocumentError.processing("Markdown 段落过多，请拆分文件后重试。")
        }
        result.append(
          Block(
            identity: identity, intents: intents,
            text: NSMutableAttributedString(string: "")))
      }
      let inline =
        run[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] ?? []
      let headerLevel = intents.compactMap { intent -> Int? in
        if case .header(let level) = intent.kind { return level }
        return nil
      }.first
      let isCode =
        inline.contains(.code)
        || intents.contains {
          if case .codeBlock = $0.kind { return true }
          return false
        }
      let bold =
        inline.contains(.stronglyEmphasized) || headerLevel != nil
        || intents.contains { $0.kind == .tableHeaderRow }
      let size: CGFloat =
        headerLevel.map { max(13, 25 - CGFloat($0) * 3) } ?? (isCode ? 10.5 : 11.5)
      var font =
        isCode
        ? NSFont(name: "Menlo-Regular", size: size)!
        : NSFont(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size)!
      if inline.contains(.emphasized) {
        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
      }
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineSpacing = 3
      paragraph.lineBreakMode = .byWordWrapping
      var attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
        .paragraphStyle: paragraph,
      ]
      if inline.contains(.strikethrough) {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self] {
        attributes[.link] = link
        attributes[.foregroundColor] = NSColor(
          calibratedRed: 0.13, green: 0.24, blue: 0.36, alpha: 1)
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
      }
      var text = String(parsed[run.range].characters)
      if run[AttributeScopes.FoundationAttributes.ImageURLAttribute.self] != nil {
        text = "[图片：\(text.isEmpty ? "未提供替代文字" : text)]"
      }
      result.last?.text.append(NSAttributedString(string: text, attributes: attributes))
    }
    return result
  }

  static func write(_ markdown: String, to outputURL: URL) throws {
    let blocks = try blocks(markdown)
    guard blocks.contains(where: { $0.text.length > 0 }) else {
      throw NativeDocumentError.invalidFile("Markdown 中没有可排版的文字。")
    }
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let context = CGContext(outputURL as CFURL, mediaBox: &box, nil) else {
      throw NativeDocumentError.processing("无法创建 Markdown PDF。")
    }
    let writer = Writer(context: context, pageBox: box)
    defer { writer.close() }
    var index = 0
    while index < blocks.count {
      try Task.checkCancellation()
      let block = blocks[index]
      if let table = block.table {
        var cells: [Block] = []
        while index < blocks.count, blocks[index].table?.id == table.id {
          cells.append(blocks[index])
          index += 1
        }
        try writer.table(cells, columns: table.columns)
      } else {
        try writer.paragraph(block)
        index += 1
      }
    }
  }

  private final class Writer {
    let context: CGContext
    let pageBox: CGRect
    let contentBox: CGRect
    var y: CGFloat
    var pageIsOpen = false
    var isClosed = false

    init(context: CGContext, pageBox: CGRect) {
      self.context = context
      self.pageBox = pageBox
      contentBox = pageBox.insetBy(dx: 52, dy: 54)
      y = contentBox.maxY
      newPage()
    }

    func newPage() {
      if pageIsOpen { context.endPDFPage() }
      context.beginPDFPage(nil)
      context.setFillColor(NSColor.white.cgColor)
      context.fill(pageBox)
      y = contentBox.maxY
      pageIsOpen = true
    }

    func close() {
      guard !isClosed else { return }
      if pageIsOpen { context.endPDFPage() }
      context.closePDF()
      isClosed = true
    }

    func paragraph(_ block: Block) throws {
      let text = NSMutableAttributedString(attributedString: block.text)
      guard text.length > 0 else { return }
      let heading = block.intents.contains {
        if case .header = $0.kind { return true }
        return false
      }
      let code = block.intents.contains {
        if case .codeBlock = $0.kind { return true }
        return false
      }
      let quote = block.intents.contains { $0.kind == .blockQuote }
      let list = block.intents.first {
        if case .listItem = $0.kind { return true }
        return false
      }
      let nesting = block.intents.filter { $0.kind == .unorderedList || $0.kind == .orderedList }
        .count
      let indent = CGFloat(min(8, nesting)) * 14 + (quote || code ? 10 : 0)
      if let list, case .listItem(let ordinal) = list.kind {
        let ordered = block.intents.contains { $0.kind == .orderedList }
        let prefix = ordered ? "\(ordinal). " : "• "
        text.insert(
          NSAttributedString(
            string: prefix, attributes: text.attributes(at: 0, effectiveRange: nil)), at: 0)
      }
      if heading { y -= 10 }
      if y - contentBox.minY < (heading ? 65 : 24) { newPage() }
      let framesetter = CTFramesetterCreateWithAttributedString(text)
      var location = 0
      while location < text.length {
        try Task.checkCancellation()
        if y - contentBox.minY < 24 { newPage() }
        let width = contentBox.width - indent
        let height = min(
          y - contentBox.minY,
          measuredHeight(framesetter, location: location, width: width))
        let rect = CGRect(x: contentBox.minX + indent, y: y - height, width: width, height: height)
        if code {
          context.setFillColor(NSColor(calibratedWhite: 0.96, alpha: 1).cgColor)
          context.fill(rect.insetBy(dx: -5, dy: -2))
        }
        if quote {
          context.setFillColor(NSColor(calibratedWhite: 0.7, alpha: 1).cgColor)
          context.fill(CGRect(x: contentBox.minX, y: rect.minY, width: 2, height: rect.height))
        }
        let frame = CTFramesetterCreateFrame(
          framesetter, CFRange(location: location, length: 0),
          CGPath(rect: rect, transform: nil), nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else { throw NativeDocumentError.processing("Markdown 段落无法排入页面。") }
        CTFrameDraw(frame, context)
        addLinks(text, frame: frame, rect: rect)
        location += visible.length
        y = rect.minY
        if location < text.length { newPage() }
      }
      y -= list == nil ? 10 : 4
    }

    func table(_ cells: [Block], columns: [PresentationIntent.TableColumn]) throws {
      guard !columns.isEmpty, columns.count <= 12 else {
        throw NativeDocumentError.processing("Markdown 表格最多支持 12 列，请拆分过宽的表格。")
      }
      let width = contentBox.width / CGFloat(columns.count)
      var rowStart = 0
      while rowStart < cells.count {
        var rowEnd = rowStart + 1
        while rowEnd < cells.count, cells[rowEnd].rowIdentity == cells[rowStart].rowIdentity {
          rowEnd += 1
        }
        var values = (0..<columns.count).map { _ in NSMutableAttributedString(string: "") }
        for cell in cells[rowStart..<rowEnd] {
          guard let intent = cell.intents.first, case .tableCell(let column) = intent.kind,
            values.indices.contains(column)
          else { continue }
          values[column] = NSMutableAttributedString(attributedString: cell.text)
          let paragraph = NSMutableParagraphStyle()
          paragraph.lineSpacing = 3
          switch columns[column].alignment {
          case .center: paragraph.alignment = .center
          case .right: paragraph.alignment = .right
          default: paragraph.alignment = .left
          }
          values[column].addAttribute(
            .paragraphStyle, value: paragraph,
            range: NSRange(location: 0, length: values[column].length))
        }
        let framesetters = values.map { CTFramesetterCreateWithAttributedString($0) }
        var locations = Array(repeating: 0, count: columns.count)
        repeat {
          try Task.checkCancellation()
          if y - contentBox.minY < 32 { newPage() }
          let needed = max(
            16,
            framesetters.indices.map {
              locations[$0] >= values[$0].length
                ? 0 : measuredHeight(framesetters[$0], location: locations[$0], width: width - 12)
            }.max() ?? 16)
          let height = min(needed + 12, y - contentBox.minY)
          var consumed = 0
          for column in columns.indices {
            let rect = CGRect(
              x: contentBox.minX + CGFloat(column) * width, y: y - height, width: width,
              height: height)
            if cells[rowStart].isTableHeader {
              context.setFillColor(NSColor(calibratedWhite: 0.94, alpha: 1).cgColor)
              context.fill(rect)
            }
            context.setStrokeColor(NSColor(calibratedWhite: 0.75, alpha: 1).cgColor)
            context.setLineWidth(0.5)
            context.stroke(rect)
            guard locations[column] < values[column].length else { continue }
            let textRect = rect.insetBy(dx: 6, dy: 6)
            let frame = CTFramesetterCreateFrame(
              framesetters[column],
              CFRange(location: locations[column], length: 0),
              CGPath(rect: textRect, transform: nil), nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
              throw NativeDocumentError.processing("Markdown 表格单元格过窄，无法排版。")
            }
            CTFrameDraw(frame, context)
            addLinks(values[column], frame: frame, rect: textRect)
            locations[column] += visible.length
            consumed += visible.length
          }
          y -= height
          let remains = locations.indices.contains { locations[$0] < values[$0].length }
          if !remains { break }
          guard consumed > 0 else { throw NativeDocumentError.processing("Markdown 表格无法排版。") }
          newPage()
        } while true
        rowStart = rowEnd
      }
      y -= 12
    }

    func measuredHeight(_ framesetter: CTFramesetter, location: Int, width: CGFloat) -> CGFloat {
      let size = CTFramesetterSuggestFrameSizeWithConstraints(
        framesetter,
        CFRange(location: location, length: 0), nil,
        CGSize(width: width, height: CGFloat.greatestFiniteMagnitude), nil)
      return ceil(size.height) + 2
    }

    func addLinks(_ text: NSAttributedString, frame: CTFrame, rect: CGRect) {
      let lines = CTFrameGetLines(frame) as! [CTLine]
      var origins = Array(repeating: CGPoint.zero, count: lines.count)
      CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
      for (index, line) in lines.enumerated() {
        let range = CTLineGetStringRange(line)
        text.enumerateAttribute(.link, in: NSRange(location: range.location, length: range.length))
        { value, linkRange, _ in
          guard let url = value as? URL,
            ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "")
          else { return }
          let start = CTLineGetOffsetForStringIndex(line, linkRange.location, nil)
          let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(linkRange), nil)
          var ascent: CGFloat = 0
          var descent: CGFloat = 0
          _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
          context.setURL(
            url as CFURL,
            for: CGRect(
              x: rect.minX + origins[index].x + start,
              y: rect.minY + origins[index].y - descent, width: max(1, end - start),
              height: ascent + descent))
        }
      }
    }
  }
}
