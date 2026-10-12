import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns a separate in-memory document; conversion inputs and results never enter this session.
@MainActor
final class PDFEditorModel: NSObject, ObservableObject {
  @Published private(set) var document: PDFDocument?
  @Published private(set) var filename = ""
  @Published var draft: PDFTextDraft?
  @Published private(set) var editingPage: Int?
  private(set) var contentData: Data?
  private var cachedBlocks: [Int: [PDFTextBlock]] = [:]
  @Published private(set) var pageNumber = 1
  @Published private(set) var isDirty = false
  @Published private(set) var canUndo = false
  @Published private(set) var canRedo = false
  @Published private(set) var notice = "点击页面中的文字，直接输入；拖动文字框顶部可移动位置。"
  @Published var error: String?
  private weak var pdfView: PDFView?
  private var sourceURL: URL?
  private var undoStates: [Data] = []
  private var redoStates: [Data] = []
  private var savedState: Data?
  private var panelOpen = false
  private var updatingView = false

  var hasPendingChanges: Bool { draft?.hasChanges == true }

  private func mayReplaceDocument() -> Bool {
    if isDirty || hasPendingChanges {
      let alert = NSAlert()
      alert.messageText = "当前 PDF 有未保存的修改"
      alert.informativeText = "打开其他文件会丢弃这些修改。可以先取消并另存为。"
      alert.addButton(withTitle: "取消")
      alert.addButton(withTitle: "丢弃修改并打开")
      return alert.runModal() == .alertSecondButtonReturn
    }
    return true
  }

  @discardableResult
  func receiveDroppedFiles(_ urls: [URL]) -> Bool {
    guard !panelOpen else { return false }
    guard urls.count == 1, let url = urls.first, url.isFileURL,
      url.pathExtension.lowercased() == "pdf"
    else {
      error = "PDF 编辑一次只能打开一个 PDF 文件。"
      return false
    }
    guard mayReplaceDocument() else { return false }
    do {
      try load(url)
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func open() {
    guard !panelOpen, mayReplaceDocument() else { return }
    let panel = NSOpenPanel()
    panel.title = "打开 PDF"
    panel.allowedContentTypes = [.pdf]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panelOpen = true
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      self.panelOpen = false
      guard response == .OK, let url = panel.url else { return }
      do { try self.load(url) } catch { self.error = error.localizedDescription }
    }
    panel.begin(completionHandler: completion)
  }

  func load(_ url: URL) throws {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let data = try Data(contentsOf: url)
    guard let loaded = PDFDocument(data: data), loaded.pageCount > 0 else {
      throw NativeDocumentError.invalidFile("无法读取这个 PDF。")
    }
    guard !loaded.isLocked, loaded.allowsDocumentChanges else {
      throw NativeDocumentError.invalidFile("这个 PDF 已加密或不允许编辑，请使用已解锁且允许编辑的副本。")
    }
    draft = nil
    editingPage = nil
    contentData = data
    cachedBlocks = [:]
    document = loaded
    filename = url.lastPathComponent
    sourceURL = url
    pageNumber = 1
    undoStates = []
    redoStates = []
    savedState = data
    isDirty = false
    resetNotice()
    updateHistory()
    if (loaded.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      notice = "这个 PDF 没有可选择的文字。请先在格式转换中识别文字。"
    }
  }

  func attach(_ view: PDFView) {
    NotificationCenter.default.removeObserver(self)
    pdfView = view
    NotificationCenter.default.addObserver(
      self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
  }

  func synchronize(_ view: PDFView) {
    if view.document !== document {
      updatingView = true
      let destination = view.currentDestination
      let scale = view.scaleFactor
      let hadDocument = view.document != nil
      view.document = document
      if hadDocument { view.scaleFactor = scale } else { view.autoScales = true }
      if let page = document?.page(at: pageNumber - 1) {
        if let destination, hadDocument {
          view.go(to: PDFDestination(page: page, at: destination.point))
        } else {
          view.go(to: page)
        }
      }
      updatingView = false
    }
    (view as? DirectEditingPDFView)?.refreshEditor()
  }

  func detach() {
    NotificationCenter.default.removeObserver(self)
    pdfView = nil
  }

  @objc private func pageChanged() {
    guard !updatingView else { return }
    guard let document, let page = pdfView?.currentPage else { return }
    let index = document.index(for: page)
    if index != NSNotFound { pageNumber = index + 1 }
  }

  func blocks(page: Int) throws -> [PDFTextBlock] {
    if let cached = cachedBlocks[page] { return cached }
    guard let contentData else { return [] }
    let blocks = try PDFContentEditor.blocks(in: contentData, page: page)
    cachedBlocks[page] = blocks
    return blocks
  }

  func beginEditing(page index: Int, at point: CGPoint) {
    guard finishEditing() else { return }
    do {
      let candidates = try blocks(page: index).filter {
        $0.bounds.insetBy(dx: -3, dy: -5).contains(point)
      }
      guard
        let block = candidates.min(by: {
          $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height
        })
      else {
        notice = "这里没有可直接编辑的文字对象。扫描图片或组合对象中的文字暂不支持。"
        return
      }
      try beginEditing(block: block, page: index)
    } catch { self.error = error.localizedDescription }
  }

  func beginEditing(block: PDFTextBlock, page index: Int) throws {
    guard let contentData else { return }
    if let limitation = block.limitation { throw NativeDocumentError.invalidOption(limitation) }
    guard document?.page(at: index)?.rotation == 0 else {
      throw NativeDocumentError.invalidOption("旋转页面暂不支持原位编辑，请先将页面转正。")
    }
    var edit = PDFTextDraft(block: block)
    let pageBounds = document?.page(at: index)?.bounds(for: .cropBox) ?? .zero
    edit.width = max(10, min(edit.width, pageBounds.maxX - edit.x - 8))
    edit.initialWidth = edit.width
    // Remove the actual source objects in the display copy while NSTextView owns
    // the live text. The unmodified bytes remain the transaction's source.
    var hidden = edit
    hidden.text = ""
    let preview = try PDFContentEditor.apply(hidden, to: contentData, page: index)
    guard let previewDocument = PDFDocument(data: preview) else { return }
    draft = edit
    editingPage = index
    pageNumber = index + 1
    document = previewDocument
    notice = "直接输入或换行。点击空白处完成，Esc 取消；拖动文字框顶部可移动。"
  }

  @discardableResult
  func finishEditing() -> Bool {
    guard let draft, let index = editingPage, let before = contentData else { return true }
    do {
      if draft.hasChanges {
        let data = try PDFContentEditor.apply(draft, to: before, page: index)
        guard let changed = PDFDocument(data: data) else { return false }
        undoStates.append(before)
        trimHistory()
        redoStates = []
        contentData = data
        document = changed
        cachedBlocks = [:]
        isDirty = data != savedState
      } else {
        document = PDFDocument(data: before)
      }
      self.draft = nil
      editingPage = nil
      resetNotice()
      updateHistory()
      return true
    } catch {
      self.error = error.localizedDescription
      return false
    }
  }

  func cancelEditing() {
    draft = nil
    editingPage = nil
    if let contentData { document = PDFDocument(data: contentData) }
    resetNotice()
  }

  func deleteBlock() {
    draft?.text = ""
    _ = finishEditing()
  }

  func undo() {
    if draft != nil {
      cancelEditing()
      return
    }
    guard let previous = undoStates.last, let restored = PDFDocument(data: previous),
      let current = contentData
    else { return }
    undoStates.removeLast()
    redoStates.append(current)
    contentData = previous
    cachedBlocks = [:]
    document = restored
    isDirty = previous != savedState
    resetNotice()
    updateHistory()
  }

  func redo() {
    guard finishEditing() else { return }
    guard let next = redoStates.last, let restored = PDFDocument(data: next),
      let current = contentData
    else { return }
    redoStates.removeLast()
    undoStates.append(current)
    contentData = next
    cachedBlocks = [:]
    document = restored
    isDirty = next != savedState
    resetNotice()
    updateHistory()
  }

  func save() {
    guard document != nil, !panelOpen, finishEditing() else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.pdf]
    panel.nameFieldStringValue = (filename as NSString).deletingPathExtension + "-编辑.pdf"
    panelOpen = true
    let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
      guard let self else { return }
      self.panelOpen = false
      guard response == .OK, let url = panel.url else { return }
      do { try self.write(to: url) } catch { self.error = error.localizedDescription }
    }
    panel.begin(completionHandler: completion)
  }

  func write(to url: URL) throws {
    guard finishEditing(), let sourceURL, let data = contentData,
      let verified = PDFDocument(data: data), verified.pageCount == document?.pageCount
    else { throw NativeDocumentError.processing("无法生成可保存的 PDF。") }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let originalID = try? sourceURL.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier
    let destinationID = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey])
      .fileResourceIdentifier
    let sameID = originalID.flatMap { $0 as? NSObject } == destinationID.flatMap { $0 as? NSObject }
    guard
      url.resolvingSymlinksInPath().standardizedFileURL
        != sourceURL.resolvingSymlinksInPath().standardizedFileURL,
      !(originalID != nil && destinationID != nil && sameID)
    else { throw NativeDocumentError.invalidOption("请使用新文件名，保留原始 PDF。") }
    try data.write(to: url, options: .atomic)
    savedState = data
    isDirty = false
    notice = "已保存为 \(url.lastPathComponent)"
  }

  func go(_ delta: Int) {
    guard finishEditing(), let document else { return }
    let index = min(document.pageCount - 1, max(0, pageNumber - 1 + delta))
    if let page = document.page(at: index) { pdfView?.go(to: page) }
  }

  func zoom(_ inward: Bool) {
    if inward { pdfView?.zoomIn(nil) } else { pdfView?.zoomOut(nil) }
  }

  private func resetNotice() {
    notice = "点击页面中的文字，直接输入；拖动文字框顶部可移动位置。"
  }

  private func updateHistory() {
    canUndo = !undoStates.isEmpty
    canRedo = !redoStates.isEmpty
  }

  private func trimHistory() {
    while undoStates.count > 20
      || (undoStates.count > 1 && undoStates.reduce(0, { $0 + $1.count }) > 100_000_000)
    {
      undoStates.removeFirst()
    }
  }
}

struct PDFEditorView: View {
  @ObservedObject var model: PDFEditorModel

  var body: some View {
    VStack(spacing: 0) {
      if model.document != nil {
        HStack {
          Text(model.filename).font(.headline).lineLimit(1)
          if model.isDirty || model.hasPendingChanges {
            Text("未保存").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("上一页", systemImage: "chevron.up") { model.go(-1) }
            .disabled(model.pageNumber <= 1)
          Text("\(model.pageNumber) / \(model.document?.pageCount ?? 0)")
            .font(.callout.monospacedDigit())
          Button("下一页", systemImage: "chevron.down") { model.go(1) }
            .disabled(model.pageNumber >= (model.document?.pageCount ?? 0))
          Divider().frame(height: 18)
          Button("缩小", systemImage: "minus.magnifyingglass") { model.zoom(false) }
          Button("放大", systemImage: "plus.magnifyingglass") { model.zoom(true) }
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .padding(.horizontal, 20).padding(.vertical, 12)
        Divider()
        HStack(spacing: 0) {
          EditorPDFCanvas(model: model)
          Divider()
          inspector.frame(width: 224)
        }
      } else {
        VStack(spacing: 16) {
          Image(systemName: "doc.text").font(.system(size: 48, weight: .light)).foregroundStyle(
            .secondary)
          Text("PDF 编辑").font(.title2.weight(.semibold))
          Text("拖入或打开 PDF，点击文字即可在页面中编辑。")
            .foregroundStyle(.secondary)
          Button("打开 PDF…") { model.open() }.buttonStyle(.borderedProminent)
            .accessibilityIdentifier("pdfEditor.openEmpty")
          Text("支持普通文字 PDF；扫描件和复杂组合文字暂不支持。")
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(TransallTheme.paper)
    .toolbar {
      ToolbarItem(placement: .principal) { Text("PDF 编辑") }
      ToolbarItem(placement: .confirmationAction) {
        Button("打开 PDF", systemImage: "folder") { model.open() }
          .accessibilityIdentifier("pdfEditor.open")
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("撤销", systemImage: "arrow.uturn.backward") { model.undo() }
          .disabled(!model.canUndo && model.draft == nil).accessibilityIdentifier("pdfEditor.undo")
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("重做", systemImage: "arrow.uturn.forward") { model.redo() }
          .disabled(!model.canRedo).accessibilityIdentifier("pdfEditor.redo")
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("另存为", systemImage: "square.and.arrow.down") { model.save() }
          .disabled(model.document == nil).keyboardShortcut("s", modifiers: .command)
          .accessibilityIdentifier("pdfEditor.save")
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .transallChooseDocuments)) { _ in
      model.open()
    }
    .alert(
      "无法完成编辑",
      isPresented: Binding(
        get: { model.error != nil }, set: { if !$0 { model.error = nil } }
      )
    ) {
      Button("关闭", role: .cancel) { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }

  private var inspector: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("文字属性").font(.headline)
      Text(model.notice).font(.callout).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      if let draft = model.draft {
        Picker("字体", selection: editBinding(\.fontName, default: draft.fontName)) {
          Text("原字体 · \(draft.block.fontName)").tag(draft.block.fontName)
          ForEach(
            [
              "Helvetica", "Times New Roman", "PingFangSC-Regular", "STSongti-SC-Regular",
              "Menlo-Regular",
            ].filter { $0 != draft.block.fontName }, id: \.self
          ) { name in
            Text(NSFont(name: name, size: 12)?.displayName ?? name).tag(name)
          }
        }
        HStack {
          Text("字号")
          TextField("字号", value: numberBinding(\.fontSize, value: 12), format: .number)
            .textFieldStyle(.roundedBorder).accessibilityIdentifier("pdfEditor.fontSize")
          Stepper("字号", value: editBinding(\.fontSize, default: 12), in: 1...300).labelsHidden()
        }
        ColorPicker(
          "文字颜色",
          selection: Binding(
            get: { Color(nsColor: model.draft?.color ?? .black) },
            set: { model.draft?.color = NSColor($0) }), supportsOpacity: false)
        Divider()
        numberField("文字框宽度", keyPath: \.width, value: draft.width)
        numberField("水平位置", keyPath: \.x, value: draft.x)
        numberField("基线位置", keyPath: \.y, value: draft.y)
        Text("单位：点。宽度决定自动换行，周围内容不会自动移动。")
          .font(.caption).foregroundStyle(.secondary)
        Button("完成编辑") { model.finishEditing() }
          .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
          .accessibilityIdentifier("pdfEditor.finish")
        HStack {
          Button("取消") { model.cancelEditing() }
          Spacer()
          Button("删除文字块", role: .destructive) { model.deleteBlock() }
        }
        if NSFont(name: draft.fontName, size: 12) == nil {
          Text("本机没有原字体，输入后将使用系统字体。可在上方选择字体。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      Spacer()
      Divider()
      Text("直接编辑 PDF 正文，保留其他文字、图片、线条和批注。修改后请另存为。")
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    .padding(16).frame(maxHeight: .infinity).background(TransallTheme.panel)
  }

  private func editBinding<Value>(
    _ keyPath: WritableKeyPath<PDFTextDraft, Value>, default value: Value
  ) -> Binding<Value> {
    Binding(
      get: { model.draft?[keyPath: keyPath] ?? value }, set: { model.draft?[keyPath: keyPath] = $0 }
    )
  }

  private func numberBinding(_ keyPath: WritableKeyPath<PDFTextDraft, CGFloat>, value: CGFloat)
    -> Binding<Double>
  {
    Binding(
      get: { Double(model.draft?[keyPath: keyPath] ?? value) },
      set: { model.draft?[keyPath: keyPath] = CGFloat($0) })
  }

  private func numberField(
    _ title: String, keyPath: WritableKeyPath<PDFTextDraft, CGFloat>, value: CGFloat
  ) -> some View {
    HStack {
      Text(title).font(.callout)
      Spacer()
      TextField(
        title, value: numberBinding(keyPath, value: value),
        format: .number.precision(.fractionLength(0...1))
      )
      .textFieldStyle(.roundedBorder).frame(width: 68)
    }
  }
}

private struct EditorPDFCanvas: NSViewRepresentable {
  @Environment(\.fileDropAction) private var fileDropAction
  let model: PDFEditorModel

  func makeCoordinator() -> PDFEditorModel { model }

  func makeNSView(context: Context) -> DirectEditingPDFView {
    let view = DirectEditingPDFView()
    view.fileDropAction = fileDropAction
    view.editorModel = model
    view.displayMode = .singlePageContinuous
    view.backgroundColor = .underPageBackgroundColor
    model.attach(view)
    return view
  }

  func updateNSView(_ view: DirectEditingPDFView, context: Context) {
    view.fileDropAction = fileDropAction
    model.synchronize(view)
  }

  static func dismantleNSView(_ view: DirectEditingPDFView, coordinator: PDFEditorModel) {
    view.stopMonitoring()
    _ = coordinator.finishEditing()
    coordinator.detach()
  }
}
