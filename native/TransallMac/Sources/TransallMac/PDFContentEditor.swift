import AppKit
import CPDFium
import CoreText
import PDFKit

struct PDFTextBlock: Identifiable {
  var id: String { objectIndices.map(String.init).joined(separator: ":") }
  let objectIndices: [Int]
  let text: String
  let bounds: CGRect
  let origin: CGPoint
  let fontName: String
  let fontSize: CGFloat
  let color: NSColor
  let limitation: String?
}

struct PDFTextDraft {
  let block: PDFTextBlock
  var text: String
  var fontName: String
  var fontSize: CGFloat
  var color: NSColor
  var x: CGFloat
  var y: CGFloat
  var width: CGFloat
  var initialWidth: CGFloat

  init(block: PDFTextBlock) {
    self.block = block
    text = block.text
    fontName = block.fontName
    fontSize = block.fontSize
    color = block.color
    x = block.origin.x
    y = block.origin.y
    width = max(140, block.bounds.width + 4)
    initialWidth = width
  }

  var hasChanges: Bool {
    text != block.text || fontName != block.fontName || fontSize != block.fontSize
      || color != block.color || x != block.origin.x || y != block.origin.y || width != initialWidth
  }

  var font: NSFont {
    let size = fontSize.isFinite ? min(300, max(1, fontSize)) : 12
    return NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
  }
}

/// PDFKit displays pages; PDFium edits their content objects without flattening.
/// All access is serialized because PDFium is not thread-safe.
@MainActor
enum PDFContentEditor {
  private static let initialized: Void = FPDF_InitLibrary()

  private final class Document {
    let bytes: NSData
    let handle: FPDF_DOCUMENT

    @MainActor
    init(_ data: Data) throws {
      _ = PDFContentEditor.initialized
      bytes = data as NSData
      guard let loaded = FPDF_LoadMemDocument64(bytes.bytes, bytes.length, nil) else {
        throw NativeDocumentError.invalidFile("无法读取 PDF 正文。")
      }
      handle = loaded
    }

    deinit { FPDF_CloseDocument(handle) }

    func page(_ index: Int) throws -> FPDF_PAGE {
      guard let page = FPDF_LoadPage(handle, Int32(index)) else {
        throw NativeDocumentError.invalidFile("无法读取 PDF 页面。")
      }
      return page
    }

    func save() throws -> Data {
      // The callback's first field is the C writer, followed by our byte sink.
      let sink = NSMutableData()
      var writer = Writer(
        callbacks: FPDF_FILEWRITE(
          version: 1,
          WriteBlock: { pointer, data, count in
            guard let pointer, let data else { return 0 }
            let writer = UnsafeRawPointer(pointer).assumingMemoryBound(to: Writer.self)
            Unmanaged<NSMutableData>.fromOpaque(writer.pointee.sink).takeUnretainedValue()
              .append(data, length: Int(count))
            return 1
          }), sink: Unmanaged.passUnretained(sink).toOpaque())
      let success = withUnsafeMutablePointer(to: &writer) {
        $0.withMemoryRebound(to: FPDF_FILEWRITE.self, capacity: 1) {
          FPDF_SaveAsCopy(handle, $0, UInt(FPDF_NO_INCREMENTAL | FPDF_SUBSET_NEW_FONTS))
        }
      }
      guard success != 0 else { throw NativeDocumentError.processing("无法保存 PDF 正文。") }
      return sink as Data
    }
  }

  private struct Writer {
    var callbacks: FPDF_FILEWRITE
    var sink: UnsafeMutableRawPointer
  }

  static func blocks(in data: Data, page index: Int) throws -> [PDFTextBlock] {
    let document = try Document(data)
    let page = try document.page(index)
    defer { FPDF_ClosePage(page) }
    guard let textPage = FPDFText_LoadPage(page) else { return [] }
    defer { FPDFText_ClosePage(textPage) }
    var blocks: [PDFTextBlock] = []
    var groupIDs: [String: Int] = [:]
    var groupBaselines: [String: CGFloat] = [:]
    for index in 0..<FPDFPage_CountObjects(page) {
      guard let object = FPDFPage_GetObject(page, index),
        FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT,
        let font = FPDFTextObj_GetFont(object)
      else { continue }
      let count = FPDFTextObj_GetText(object, textPage, nil, 0)
      guard count > 2 else { continue }
      var buffer = [UInt16](repeating: 0, count: Int(count) / 2)
      _ = FPDFTextObj_GetText(object, textPage, &buffer, count)
      let text = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF16.self)
      guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
      var left: Float = 0
      var bottom: Float = 0
      var right: Float = 0
      var top: Float = 0
      var size: Float = 0
      var matrix = FS_MATRIX()
      guard FPDFPageObj_GetBounds(object, &left, &bottom, &right, &top) != 0,
        FPDFPageObj_GetMatrix(object, &matrix) != 0,
        FPDFTextObj_GetFontSize(object, &size) != 0
      else { continue }
      let fontCount = FPDFFont_GetBaseFontName(font, nil, 0)
      var name = [CChar](repeating: 0, count: max(1, Int(fontCount)))
      _ = FPDFFont_GetBaseFontName(font, &name, name.count)
      let fullName = String(cString: name)
      let fontName = fullName.split(separator: "+").last.map(String.init) ?? fullName
      var r: UInt32 = 0
      var g: UInt32 = 0
      var b: UInt32 = 0
      var a: UInt32 = 255
      _ = FPDFPageObj_GetFillColor(object, &r, &g, &b, &a)
      let effectiveSize = CGFloat(abs(size * matrix.d))
      let horizontal =
        abs(matrix.b) < 0.001 && abs(matrix.c) < 0.001 && matrix.a > 0 && matrix.d > 0
      let visible = FPDFTextObj_GetTextRenderMode(object) == FPDF_TEXTRENDERMODE_FILL && a > 0
      let block = PDFTextBlock(
        objectIndices: [Int(index)], text: text,
        bounds: CGRect(
          x: CGFloat(left), y: CGFloat(bottom), width: CGFloat(right - left),
          height: CGFloat(top - bottom)),
        origin: CGPoint(x: CGFloat(matrix.e), y: CGFloat(matrix.f)), fontName: fontName,
        fontSize: max(1, effectiveSize),
        color: NSColor(
          srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255,
          alpha: CGFloat(a) / 255),
        limitation: !horizontal ? "旋转或倾斜的文字暂不支持原位编辑。" : (!visible ? "描边、裁剪或隐藏文字暂不支持原位编辑。" : nil))
      if let group = editGroup(object), let previousIndex = groupIDs[group] {
        let previous = blocks[previousIndex]
        let separator =
          abs((groupBaselines[group] ?? previous.origin.y) - block.origin.y) > block.fontSize * 0.5
          ? "\n" : ""
        groupBaselines[group] = block.origin.y
        blocks[previousIndex] = PDFTextBlock(
          objectIndices: previous.objectIndices + block.objectIndices,
          text: previous.text + separator + block.text,
          bounds: previous.bounds.union(block.bounds), origin: previous.origin,
          fontName: previous.fontName, fontSize: previous.fontSize, color: previous.color,
          limitation: previous.limitation ?? block.limitation)
      } else {
        if let group = editGroup(object) {
          groupIDs[group] = blocks.count
          groupBaselines[group] = block.origin.y
        }
        blocks.append(block)
      }
    }
    return blocks
  }

  private static func editGroup(_ object: FPDF_PAGEOBJECT) -> String? {
    for index in 0..<FPDFPageObj_CountMarks(object) {
      guard let mark = FPDFPageObj_GetMark(object, UInt(index)) else { continue }
      var count: UInt = 0
      guard FPDFPageObjMark_GetName(mark, nil, 0, &count) != 0, count > 2 else { continue }
      var name = [UInt16](repeating: 0, count: Int(count) / 2)
      guard FPDFPageObjMark_GetName(mark, &name, count, &count) != 0 else { continue }
      let value = String(decoding: name.prefix(while: { $0 != 0 }), as: UTF16.self)
      if value.hasPrefix("TransallEdit_") { return value }
    }
    return nil
  }

  static func objectCounts(in data: Data, page index: Int) throws -> (images: Int, paths: Int) {
    let document = try Document(data)
    let page = try document.page(index)
    defer { FPDF_ClosePage(page) }
    var images = 0
    var paths = 0
    for index in 0..<FPDFPage_CountObjects(page) {
      let type = FPDFPageObj_GetType(FPDFPage_GetObject(page, index))
      if type == FPDF_PAGEOBJ_IMAGE { images += 1 }
      if type == FPDF_PAGEOBJ_PATH { paths += 1 }
    }
    return (images, paths)
  }

  static func apply(_ draft: PDFTextDraft, to data: Data, page index: Int) throws -> Data {
    if let limitation = draft.block.limitation {
      throw NativeDocumentError.invalidOption(limitation)
    }
    guard draft.text.utf16.count <= 20_000, draft.fontSize.isFinite,
      (1...300).contains(draft.fontSize), draft.width.isFinite, draft.width >= 10,
      draft.x.isFinite, draft.y.isFinite
    else { throw NativeDocumentError.invalidOption("请输入有效的字号、位置和文本框宽度；每个文字块最多 20,000 字。") }
    let document = try Document(data)
    let page = try document.page(index)
    defer { FPDF_ClosePage(page) }
    try normalizeColors(page)
    let objects = try draft.block.objectIndices.map { index -> FPDF_PAGEOBJECT in
      guard let object = FPDFPage_GetObject(page, Int32(index)),
        FPDFPageObj_GetType(object) == FPDF_PAGEOBJ_TEXT
      else {
        throw NativeDocumentError.processing("文字对象已变化，请重新选择。")
      }
      return object
    }
    // Position-only edits keep original fonts, kerning, and graphics state intact.
    if draft.text == draft.block.text && draft.fontName == draft.block.fontName
      && draft.fontSize == draft.block.fontSize && draft.color == draft.block.color
      && draft.width == draft.initialWidth
    {
      for object in objects {
        FPDFPageObj_Transform(
          object, 1, 0, 0, 1, Double(draft.x - draft.block.origin.x),
          Double(draft.y - draft.block.origin.y))
      }
    } else {
      let insertionIndex = draft.block.objectIndices.min() ?? 0
      for object in objects {
        guard FPDFPage_RemoveObject(page, object) != 0 else {
          throw NativeDocumentError.processing("无法修改这个文字对象。")
        }
        FPDFPageObj_Destroy(object)
      }
      if !draft.text.isEmpty {
        try insert(draft, document: document.handle, page: page, at: insertionIndex)
      }
    }
    guard FPDFPage_GenerateContent(page) != 0 else {
      throw NativeDocumentError.processing("无法生成编辑后的页面。")
    }
    let result = try document.save()
    guard let verified = PDFDocument(data: result),
      verified.pageCount == FPDF_GetPageCount(document.handle)
    else {
      throw NativeDocumentError.processing("编辑后的 PDF 未通过读取检查。")
    }
    return result
  }

  private static func insert(
    _ draft: PDFTextDraft, document: FPDF_DOCUMENT, page: FPDF_PAGE, at index: Int
  ) throws {
    let text = draft.text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(
      of: "\r", with: "\n")
    let attributes: [NSAttributedString.Key: Any] = [
      .font: draft.font, .foregroundColor: draft.color,
    ]
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let string = text as NSString
    var offset = 0
    var lineNumber = 0
    var insertionIndex = index
    var fonts: [String: FPDF_FONT] = [:]
    defer { for font in fonts.values { FPDFFont_Close(font) } }
    let group = "TransallEdit_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let color = draft.color.usingColorSpace(.sRGB) ?? .black
    let lineHeight = ceil(draft.font.ascender - draft.font.descender + draft.font.leading) * 1.15
    while offset < attributed.length {
      let length = max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(draft.width)))
      let line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length))
      let baseline = draft.y - CGFloat(lineNumber) * lineHeight
      guard baseline >= 0 else { throw NativeDocumentError.invalidOption("文字超出页面底部，请移动文字块或减小字号。") }
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let range = CTRunGetStringRange(run)
        let value = string.substring(with: NSRange(location: range.location, length: range.length))
          .trimmingCharacters(in: .newlines)
        guard !value.isEmpty else { continue }
        let runAttributes = CTRunGetAttributes(run) as NSDictionary
        let font = runAttributes[kCTFontAttributeName] as! CTFont
        let key = CTFontCopyPostScriptName(font) as String
        let loaded: FPDF_FONT
        if let cached = fonts[key] {
          loaded = cached
        } else {
          let bytes = try fontData(font, characters: text)
          guard
            let result = bytes.withUnsafeBytes({ buffer in
              FPDFText_LoadFont(
                document, buffer.bindMemory(to: UInt8.self).baseAddress, UInt32(buffer.count),
                FPDF_FONT_TRUETYPE, 1)
            })
          else { throw NativeDocumentError.processing("无法嵌入字体 \(key)，请换用其他字体。") }
          fonts[key] = result
          loaded = result
        }
        guard let object = FPDFPageObj_CreateTextObj(document, loaded, Float(draft.fontSize)) else {
          throw NativeDocumentError.processing("无法创建文字对象。")
        }
        let utf16 = Array(value.utf16) + [0]
        guard FPDFText_SetText(object, utf16) != 0 else {
          FPDFPageObj_Destroy(object)
          throw NativeDocumentError.processing("这个字体无法显示输入的文字，请换用其他字体。")
        }
        let x = draft.x + CTLineGetOffsetForStringIndex(line, range.location, nil)
        var matrix = FS_MATRIX(a: 1, b: 0, c: 0, d: 1, e: Float(x), f: Float(baseline))
        _ = FPDFPageObj_SetMatrix(object, &matrix)
        _ = FPDFPageObj_SetFillColor(
          object, UInt32(color.redComponent * 255), UInt32(color.greenComponent * 255),
          UInt32(color.blueComponent * 255), UInt32(color.alphaComponent * 255))
        _ = FPDFPageObj_AddMark(object, group)
        guard FPDFPage_InsertObjectAtIndex(page, object, insertionIndex) != 0 else {
          FPDFPageObj_Destroy(object)
          throw NativeDocumentError.processing("无法插入修改后的文字。")
        }
        insertionIndex += 1
      }
      offset += length
      lineNumber += 1
    }
  }

  /// Rebuild a single SFNT face from CoreText tables. This also handles fonts
  /// stored in TTC collections and lets CoreText choose CJK fallback fonts.
  private static func fontData(_ font: CTFont, characters: String) throws -> Data {
    guard let available = CTFontCopyAvailableTables(font, CTFontTableOptions(rawValue: 0)),
      CFArrayGetCount(available) > 0
    else {
      throw NativeDocumentError.processing("无法读取字体数据。")
    }
    // CoreText stores integer tags as raw pointer values, not CFNumber objects.
    let tags = (0..<CFArrayGetCount(available)).map {
      UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(available, $0)))
    }
    let tables = tags.sorted().compactMap { tag -> (UInt32, Data)? in
      if tag == 0x636D_6170 { return (tag, characterMap(font, characters: characters)) }
      if tag == 0x4453_4947 { return nil }
      guard let table = CTFontCopyTable(font, tag, CTFontTableOptions(rawValue: 0)) else {
        return nil
      }
      // Font tables can be backed by read-only mapped system font memory.
      var bytes = Data(bytes: CFDataGetBytePtr(table), count: CFDataGetLength(table))
      if tag == 0x6865_6164 && bytes.count >= 12 {
        bytes.replaceSubrange(8..<12, with: [0, 0, 0, 0])
      }
      return (tag, bytes)
    }
    // PDFium's TrueType loader also accepts OpenType with CFF outlines.
    let cff = tables.contains { $0.0 == 0x4346_4620 }
    var result = Data()
    func u16(_ value: Int) {
      result.append(UInt8((value >> 8) & 255))
      result.append(UInt8(value & 255))
    }
    func u32(_ value: UInt32) {
      for shift in [24, 16, 8, 0] { result.append(UInt8((value >> shift) & 255)) }
    }
    u32(cff ? 0x4F54_544F : 0x0001_0000)
    u16(tables.count)
    let power = Int(log2(Double(tables.count)))
    u16((1 << power) * 16)
    u16(power)
    u16(tables.count * 16 - (1 << power) * 16)
    var offset = 12 + tables.count * 16
    var headOffset: Int?
    for (tag, bytes) in tables {
      u32(tag)
      u32(checksum(bytes))
      u32(UInt32(offset))
      u32(UInt32(bytes.count))
      if tag == 0x6865_6164 { headOffset = offset }
      offset += (bytes.count + 3) & ~3
    }
    for (_, bytes) in tables {
      result.append(bytes)
      while result.count % 4 != 0 { result.append(0) }
    }
    if let headOffset {
      let adjustment = 0xB1B0_AFBA &- checksum(result)
      for (index, shift) in [24, 16, 8, 0].enumerated() {
        result[headOffset + 8 + index] = UInt8((adjustment >> shift) & 255)
      }
    }
    return result
  }

  /// PDFium's writer supports RGB/gray color operators. Resolve ICC/CMYK solid
  /// colors before regenerating a stream; reject patterns instead of dropping them.
  private static func normalizeColors(_ page: FPDF_PAGE) throws {
    for index in 0..<FPDFPage_CountObjects(page) {
      guard let object = FPDFPage_GetObject(page, index) else { continue }
      let type = FPDFPageObj_GetType(object)
      guard
        [FPDF_PAGEOBJ_TEXT, FPDF_PAGEOBJ_PATH, FPDF_PAGEOBJ_IMAGE, FPDF_PAGEOBJ_FORM].contains(type)
      else {
        throw NativeDocumentError.invalidOption("这一页含有暂不支持的渐变或特殊绘图对象，无法安全编辑正文。")
      }
      guard type == FPDF_PAGEOBJ_TEXT || type == FPDF_PAGEOBJ_PATH else { continue }
      var r: UInt32 = 0
      var g: UInt32 = 0
      var b: UInt32 = 0
      var a: UInt32 = 0
      guard FPDFPageObj_GetFillColor(object, &r, &g, &b, &a) != 0 else {
        throw NativeDocumentError.invalidOption("这一页包含特殊填充，暂不支持正文编辑。")
      }
      _ = FPDFPageObj_SetFillColor(object, r, g, b, a)
      guard FPDFPageObj_GetStrokeColor(object, &r, &g, &b, &a) != 0 else {
        throw NativeDocumentError.invalidOption("这一页包含特殊描边，暂不支持正文编辑。")
      }
      _ = FPDFPageObj_SetStrokeColor(object, r, g, b, a)
    }
  }

  /// Limit cmap to the input's Unicode scalars. System CJK fonts often map both
  /// a normal character and its Kangxi radical to the same glyph; PDFium's
  /// generated ToUnicode otherwise chooses the radical and breaks copy/search.
  private static func characterMap(_ font: CTFont, characters: String) -> Data {
    var mappings: [(UInt32, UInt32)] = []
    for scalar in Set(characters.unicodeScalars.map(\.value)).sorted() {
      guard let unicode = UnicodeScalar(scalar) else { continue }
      let units = Array(String(unicode).utf16)
      var glyphs = [CGGlyph](repeating: 0, count: units.count)
      if CTFontGetGlyphsForCharacters(font, units, &glyphs, units.count), let glyph = glyphs.first,
        glyph != 0
      {
        mappings.append((scalar, UInt32(glyph)))
      }
    }
    var data = Data()
    func u16(_ value: UInt16) {
      data.append(UInt8(value >> 8))
      data.append(UInt8(value & 255))
    }
    func u32(_ value: UInt32) {
      for shift in [24, 16, 8, 0] { data.append(UInt8((value >> shift) & 255)) }
    }
    u16(0)
    u16(1)  // one Unicode encoding record
    u16(3)
    u16(10)
    u32(12)  // Windows UCS-4, subtable offset
    u16(12)
    u16(0)
    u32(UInt32(16 + mappings.count * 12))
    u32(0)
    u32(UInt32(mappings.count))
    for (scalar, glyph) in mappings {
      u32(scalar)
      u32(scalar)
      u32(glyph)
    }
    return data
  }

  private static func checksum(_ data: Data) -> UInt32 {
    var sum: UInt32 = 0
    for offset in stride(from: 0, to: data.count, by: 4) {
      var word: UInt32 = 0
      for index in 0..<4 {
        word = (word << 8) | (offset + index < data.count ? UInt32(data[offset + index]) : 0)
      }
      sum = sum &+ word
    }
    return sum
  }
}
