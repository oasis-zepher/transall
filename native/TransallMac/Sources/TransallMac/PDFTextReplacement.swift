import AppKit
import CoreText
import PDFKit

/// Redraw only changed pages so replaced text is removed from the result's text layer.
/// Reattach the remaining text invisibly; an overlay alone would leave the old text searchable.
enum PDFTextReplacement {
  static func apply(
    to document: PDFDocument, find: String, replacement: String,
    pageIndex: Int? = nil, selectedRange: NSRange? = nil
  ) throws {
    guard !find.isEmpty, find != replacement else { return }
    var matches = 0
    for index in 0..<document.pageCount {
      if let pageIndex, index != pageIndex { continue }
      try Task.checkCancellation()
      guard let original = document.page(at: index), let text = original.string else { continue }
      let string = text as NSString
      var ranges: [NSRange] = []
      if let selectedRange {
        guard selectedRange.location != NSNotFound, selectedRange.location >= 0,
          selectedRange.length > 0, selectedRange.location <= string.length,
          selectedRange.length <= string.length - selectedRange.location,
          string.substring(with: selectedRange) == find
        else { throw NativeDocumentError.invalidOption("选中文字已变化，请重新选择。") }
        ranges = [selectedRange]
      }
      var cursor = 0
      while selectedRange == nil && cursor < string.length {
        let range = string.range(
          of: find, range: NSRange(location: cursor, length: string.length - cursor))
        if range.location == NSNotFound { break }
        ranges.append(range)
        cursor = NSMaxRange(range)
        guard ranges.count <= 5_000 else {
          throw NativeDocumentError.invalidOption("匹配文字过多，请缩小查找范围。")
        }
      }
      guard !ranges.isEmpty else { continue }
      guard let page = original.copy() as? PDFPage else {
        throw NativeDocumentError.processing("无法读取待替换页面。")
      }
      page.rotation = 0
      let media = page.bounds(for: .mediaBox)
      guard media.width > 0, media.height > 0, media.width.isFinite, media.height.isFinite else {
        throw NativeDocumentError.invalidFile("页面尺寸无效。")
      }
      let scale = min(3, 3_508 / max(media.width, media.height))
      guard
        let bitmap = CGContext(
          data: nil, width: max(1, Int(media.width * scale)),
          height: max(1, Int(media.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
      else { throw NativeDocumentError.processing("无法重绘修改页。") }
      bitmap.scaleBy(x: scale, y: scale)
      bitmap.translateBy(x: -media.minX, y: -media.minY)
      bitmap.setFillColor(NSColor.white.cgColor)
      bitmap.fill(media)
      page.draw(with: .mediaBox, to: bitmap)
      var replacements: [(CGRect, CTLine)] = []
      for range in ranges {
        guard let selection = page.selection(for: range), selection.selectionsByLine().count == 1
        else {
          throw NativeDocumentError.invalidOption("查找内容跨行，请分段替换。")
        }
        let rect = selection.bounds(for: page)
        guard !rect.isEmpty, media.contains(rect) else {
          throw NativeDocumentError.processing("无法定位替换文字。")
        }
        let sourceValue = string.substring(with: range)
        let tokens = sourceValue.split(whereSeparator: { $0.isWhitespace })
        let isCharacterGrid =
          selectedRange != nil && tokens.count > 1
          && tokens.allSatisfy { $0.count == 1 }
        if isCharacterGrid {
          // Comb-style forms draw one letter in each cell. Erase and redraw only
          // the glyph boxes, leaving the vertical rules between cells intact.
          let letters = replacement.filter { !$0.isWhitespace }.map(String.init)
          guard letters.count <= tokens.count else {
            throw NativeDocumentError.invalidOption("所选区域只有 \(tokens.count) 个字符格，请缩短文字或选中更多字符格。")
          }
          var offset = range.location
          var letterIndex = 0
          for character in sourceValue {
            let length = String(character).utf16.count
            defer { offset += length }
            guard !character.isWhitespace else { continue }
            guard let glyph = page.selection(for: NSRange(location: offset, length: length)) else {
              throw NativeDocumentError.processing("无法定位字符格。")
            }
            let box = glyph.bounds(for: page)
            guard !box.isEmpty, media.contains(box) else {
              throw NativeDocumentError.processing("字符格位置无效。")
            }
            let value = letterIndex < letters.count ? letters[letterIndex] : ""
            let style = glyph.attributedString
            let line = try fittedLine(value, rect: box, style: style)
            bitmap.setFillColor(NSColor.white.cgColor)
            bitmap.fill(box)
            replacements.append((box, line))
            letterIndex += 1
          }
        } else {
          let line = try fittedLine(
            replacement, rect: rect, style: selectedRange == nil ? nil : selection.attributedString)
          bitmap.setFillColor(NSColor.white.cgColor)
          bitmap.fill(rect.insetBy(dx: -0.5, dy: -0.5))
          replacements.append((rect, line))
        }
      }
      guard let image = bitmap.makeImage() else {
        throw NativeDocumentError.processing("无法生成修改页图像。")
      }
      let data = NSMutableData()
      var box = media
      guard let consumer = CGDataConsumer(data: data),
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)
      else { throw NativeDocumentError.processing("无法生成修改页。") }
      context.beginPDFPage(nil)
      context.draw(image, in: media)
      // Restore only text outside the replaced ranges, maintaining searchable untouched text.
      var start = 0
      for range in ranges + [NSRange(location: string.length, length: 0)] {
        // A range starting on PDFKit's synthetic newline can select the previous
        // glyph again. Exclude boundary whitespace before restoring the text layer.
        var keptStart = start
        var keptEnd = range.location
        while keptStart < keptEnd,
          string.substring(with: NSRange(location: keptStart, length: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          keptStart += 1
        }
        while keptEnd > keptStart,
          string.substring(with: NSRange(location: keptEnd - 1, length: 1))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          keptEnd -= 1
        }
        if keptEnd > keptStart,
          let kept = page.selection(for: NSRange(location: keptStart, length: keptEnd - keptStart))
        {
          for line in kept.selectionsByLine() {
            let bounds = line.bounds(for: page)
            if let value = line.string, !value.isEmpty, bounds.width > 0, bounds.height > 0 {
              draw(
                try fittedLine(value, rect: bounds, requiresFit: false), in: bounds,
                context: context, invisible: true)
            }
          }
        }
        start = NSMaxRange(range)
      }
      for (rect, line) in replacements { draw(line, in: rect, context: context, invisible: false) }
      context.endPDFPage()
      context.closePDF()
      guard let rendered = PDFDocument(data: data as Data)?.page(at: 0) else {
        throw NativeDocumentError.processing("无法读取修改页结果。")
      }
      for boxType: PDFDisplayBox in [.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
        rendered.setBounds(original.bounds(for: boxType), for: boxType)
      }
      rendered.rotation = original.rotation
      document.removePage(at: index)
      document.insert(rendered, at: index)
      matches += ranges.count
    }
    guard matches > 0 else {
      throw NativeDocumentError.invalidOption("没有找到“\(find)”。请检查文字；扫描件需先识别文字。")
    }
  }

  private static func fittedLine(
    _ value: String, rect: CGRect, requiresFit: Bool = true, style: NSAttributedString? = nil
  ) throws -> CTLine {
    let attributes = style.flatMap {
      $0.length > 0 ? $0.attributes(at: 0, effectiveRange: nil) : nil
    }
    let sourceFont = attributes?[.font] as? NSFont
    let color = attributes?[.foregroundColor] as? NSColor ?? .black
    var size = sourceFont?.pointSize ?? max(8, min(36, rect.height * 0.85))
    func line(_ size: CGFloat) -> CTLine {
      CTLineCreateWithAttributedString(
        NSAttributedString(
          string: value,
          attributes: [
            .font: sourceFont.flatMap { NSFont(name: $0.fontName, size: size) }
              ?? NSFont.systemFont(ofSize: size),
            .foregroundColor: color,
          ]))
    }
    var result = line(size)
    let width = CTLineGetTypographicBounds(result, nil, nil, nil)
    if width > rect.width {
      size *= rect.width / width
      result = line(size)
    }
    guard !requiresFit || value.isEmpty || size >= 8 else {
      throw NativeDocumentError.invalidOption("替换文字太长，无法在原位置清晰显示。请缩短文字。")
    }
    return result
  }
  private static func draw(_ line: CTLine, in rect: CGRect, context: CGContext, invisible: Bool) {
    context.saveGState()
    context.textMatrix = .identity
    context.setTextDrawingMode(invisible ? .invisible : .fill)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
    context.textPosition = CGPoint(
      x: rect.minX, y: rect.minY + max(0, (rect.height - ascent - descent) / 2) + descent)
    CTLineDraw(line, context)
    context.restoreGState()
  }
}
