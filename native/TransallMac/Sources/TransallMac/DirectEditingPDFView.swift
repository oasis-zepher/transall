import AppKit
import PDFKit

/// Native text input stays on the page, including IME composition and selection.
final class DirectEditingPDFView: FileReceivingPDFView {
  weak var editorModel: PDFEditorModel?
  private var observers: [NSObjectProtocol] = []
  private var inlineEditor: PDFInlineTextEditor?
  private var refreshing = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    stopMonitoring()
    guard window != nil else { return }
    for name in [
      Notification.Name.PDFViewScaleChanged, .PDFViewPageChanged,
      NSView.boundsDidChangeNotification,
    ] {
      observers.append(
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
          [weak self] _ in
          MainActor.assumeIsolated { self?.refreshEditor() }
        })
    }
    // Scroll notifications let the input box track its PDF page precisely.
    findScrollView(in: self)?.contentView.postsBoundsChangedNotifications = true
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    let hit = super.hitTest(point)
    if let editor = inlineEditor, let hit, hit === editor || hit.isDescendant(of: editor) {
      return hit
    }
    let local = convert(point, from: superview)
    // PDFKit's private document subviews normally consume mouseDown. In edit
    // mode route page clicks through this view's responder; keep native input
    // controls and scrollbars as their own hit targets.
    guard bounds.contains(local), page(for: local, nearest: false) != nil else { return hit }
    return self
  }

  override func mouseDown(with event: NSEvent) {
    if !beginEditing(atWindowPoint: event.locationInWindow) { super.mouseDown(with: event) }
  }

  override func scrollWheel(with event: NSEvent) {
    if let scroll = findScrollView(in: self) {
      scroll.scrollWheel(with: event)
    } else {
      super.scrollWheel(with: event)
    }
  }

  @discardableResult
  func beginEditing(atWindowPoint windowPoint: CGPoint) -> Bool {
    // Specify NSView explicitly: PDFView also overloads convert(_:from:) for
    // optional PDFPage, so an untyped nil can silently select page conversion.
    let point = convert(windowPoint, from: nil as NSView?)
    guard bounds.contains(point), let model = editorModel else { return false }
    if let editor = inlineEditor, editor.frame.contains(point) { return false }
    guard let page = page(for: point, nearest: false), let document else { return false }
    let pagePoint = convert(point, to: page)
    let index = document.index(for: page)
    guard index != NSNotFound else { return false }
    model.beginEditing(page: index, at: pagePoint)
    model.synchronize(self)
    return true
  }

  func stopMonitoring() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
  }

  private func findScrollView(in view: NSView) -> NSScrollView? {
    for child in view.subviews {
      if let scroll = child as? NSScrollView { return scroll }
      if let scroll = findScrollView(in: child) { return scroll }
    }
    return nil
  }

  override func layout() {
    super.layout()
    refreshEditor()
  }

  func refreshEditor() {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    guard let model = editorModel, let draft = model.draft, let index = model.editingPage,
      let page = document?.page(at: index)
    else {
      inlineEditor?.removeFromSuperview()
      inlineEditor = nil
      return
    }
    let created = inlineEditor == nil
    let editor = inlineEditor ?? PDFInlineTextEditor()
    if created {
      inlineEditor = editor
      addSubview(editor)
      editor.onChange = { [weak model, weak self] text in
        model?.draft?.text = text
        self?.refreshEditor()
      }
      editor.onFinish = { [weak model] in _ = model?.finishEditing() }
      editor.onCancel = { [weak model] in model?.cancelEditing() }
      editor.onMove = { [weak self, weak model] delta in
        guard let self, let model, let index = model.editingPage,
          let page = self.document?.page(at: index)
        else { return }
        let origin = self.convert(CGPoint.zero, to: page)
        let moved = self.convert(delta, to: page)
        model.draft?.x += moved.x - origin.x
        model.draft?.y += moved.y - origin.y
        self.refreshEditor()
      }
    }
    let scale = max(0.05, scaleFactor)
    editor.configure(draft, scale: scale)
    let anchor = convert(CGPoint(x: draft.x, y: draft.y + draft.font.ascender), from: page)
    let width = max(24, max(10, min(10_000, draft.width)) * scale + 8)
    let height = editor.requiredHeight(width: width)
    editor.frame = CGRect(
      x: anchor.x - 4, y: anchor.y - height + 4, width: width,
      height: height + PDFInlineTextEditor.gripHeight)
    if created {
      window?.makeFirstResponder(editor.textView)
      editor.textView.setSelectedRange(
        NSRange(location: editor.textView.string.utf16.count, length: 0))
    }
  }
}

private final class PDFInlineTextEditor: NSView, NSTextViewDelegate {
  static let gripHeight: CGFloat = 18
  let textView = PDFInlineTextView()
  private let scrollView = NSScrollView()
  var onChange: ((String) -> Void)?
  var onFinish: (() -> Void)?
  var onCancel: (() -> Void)?
  var onMove: ((CGPoint) -> Void)?
  private var settingText = false
  private var dragPoint: CGPoint?
  override var isFlipped: Bool { true }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.controlAccentColor.cgColor
    layer?.cornerRadius = 3
    textView.isRichText = false
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainerInset = NSSize(width: 4, height: 4)
    textView.delegate = self
    textView.setAccessibilityLabel("页面内文字编辑")
    textView.setAccessibilityIdentifier("pdfEditor.inlineText")
    textView.onFinish = { [weak self] in self?.onFinish?() }
    textView.onCancel = { [weak self] in self?.onCancel?() }
    scrollView.drawsBackground = false
    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.documentView = textView
    addSubview(scrollView)
    setAccessibilityLabel("拖动以移动文字块")
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(_ draft: PDFTextDraft, scale: CGFloat) {
    settingText = true
    defer { settingText = false }
    if textView.string != draft.text && !textView.hasMarkedText() { textView.string = draft.text }
    let font =
      NSFont(name: draft.font.fontName, size: draft.font.pointSize * scale)
      ?? NSFont.systemFont(ofSize: draft.font.pointSize * scale)
    if textView.font != font { textView.font = font }
    textView.textColor = draft.color
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = ceil(font.ascender - font.descender + font.leading) * 0.15
    textView.defaultParagraphStyle = paragraph
    textView.typingAttributes = [
      .font: font, .foregroundColor: draft.color, .paragraphStyle: paragraph,
    ]
    if !textView.hasMarkedText() {
      textView.textStorage?.addAttribute(
        .paragraphStyle, value: paragraph,
        range: NSRange(location: 0, length: textView.string.utf16.count))
    }
  }

  func requiredHeight(width: CGFloat) -> CGFloat {
    textView.textContainer?.containerSize = NSSize(
      width: max(10, width - 8), height: .greatestFiniteMagnitude)
    if let container = textView.textContainer {
      textView.layoutManager?.ensureLayout(for: container)
    }
    let used =
      textView.textContainer.flatMap { textView.layoutManager?.usedRect(for: $0).height } ?? 24
    return max(24, used + 10)
  }

  override func layout() {
    super.layout()
    scrollView.frame = CGRect(
      x: 0, y: Self.gripHeight, width: bounds.width, height: max(1, bounds.height - Self.gripHeight)
    )
    textView.frame.size = NSSize(width: bounds.width, height: max(1, scrollView.bounds.height))
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
    bounds.fill()
    ("移动文字" as NSString).draw(
      at: CGPoint(x: 6, y: 2),
      withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.labelColor])
  }

  func textDidChange(_ notification: Notification) {
    guard !settingText else { return }
    onChange?(textView.string)
  }

  override func mouseDown(with event: NSEvent) { dragPoint = event.locationInWindow }
  override func mouseDragged(with event: NSEvent) {
    guard let previous = dragPoint else { return }
    let current = event.locationInWindow
    onMove?(CGPoint(x: current.x - previous.x, y: current.y - previous.y))
    dragPoint = current
  }
  override func mouseUp(with event: NSEvent) { dragPoint = nil }
}

private final class PDFInlineTextView: NSTextView {
  var onFinish: (() -> Void)?
  var onCancel: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 && !hasMarkedText() {
      onCancel?()
      return
    }
    if event.keyCode == 36 && event.modifierFlags.contains(.command) {
      onFinish?()
      return
    }
    super.keyDown(with: event)
  }
}
