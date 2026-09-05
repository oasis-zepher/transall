import AppKit
import PDFKit
import SwiftUI

struct DocumentInspectionSnapshot: Sendable {
  let directory: URL
  let result: URL?
  let original: URL?
  let issues: [TranslationLayoutIssue]

  init(
    directory: URL, result: URL?, original: URL?, issues: [TranslationLayoutIssue] = []
  ) {
    self.directory = directory
    self.result = result
    self.original = original
    self.issues = issues
  }
}

struct DocumentInspectionRequest: Identifiable {
  let jobID: String
  let page: Int
  var id: String { jobID }
}

struct DocumentInspectionView: View {
  let backend: NativeDocumentEngine
  let request: DocumentInspectionRequest
  @Environment(\.dismiss) private var dismiss
  @StateObject private var session = InspectionSession()
  @State private var snapshot: DocumentInspectionSnapshot?
  @State private var error: String?
  @State private var compare = true
  @State private var scale: CGFloat = 1
  @State private var selectedIssueID: String?

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text(snapshot?.result == nil && snapshot != nil ? "检查排版问题" : "检查文档")
          .font(.headline)
        Spacer()
        TransallControlGroup(spacing: 10) {
          HStack(spacing: 10) {
            if snapshot?.original != nil, snapshot?.result != nil {
              TransallGlassBar {
                HStack(spacing: 12) {
                  Toggle("原文对照", isOn: $compare).toggleStyle(.checkbox)
                  if compare {
                    Toggle("同页联动", isOn: $session.synchronize).toggleStyle(.checkbox)
                      .disabled(!session.canSynchronize)
                      .help("按相同页码和页面位置联动；不判断两侧内容是否对应")
                  }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
              }
            }
            TransallGlassBar {
              HStack(spacing: 12) {
                Button("缩小", systemImage: "minus.magnifyingglass") {
                  scale = max(0.25, scale / 1.25)
                }
                .labelStyle(.iconOnly).help("缩小文档")
                Button("放大", systemImage: "plus.magnifyingglass") {
                  scale = min(4, scale * 1.25)
                }
                .labelStyle(.iconOnly).help("放大文档")
                Button("适合页面") { scale = 1 }
              }
              .buttonStyle(.borderless)
              .padding(.horizontal, 12).padding(.vertical, 10)
            }
            TransallGlassBar {
              Button("完成") { dismiss() }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
          }
        }
      }
      .padding(14)
      if let snapshot {
        if snapshot.result == nil {
          Label(
            snapshot.issues.isEmpty
              ? "尚未生成结果。可检查提交时的原文，已保存译文可用于继续排版。"
              : "尚未生成结果。以下区域的译文排不下，请检查原文位置与已保存译文。",
            systemImage: "exclamationmark.triangle"
          )
          .font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
          Divider()
        } else if compare, session.pageCountsDiffer {
          Text("原文与结果页数不同，同页联动已停用；请分别定位内容。")
            .font(.caption).foregroundStyle(TransallTheme.inkSoft)
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
          Divider()
        }
        HStack(spacing: 1) {
          if compare || snapshot.result == nil, let original = snapshot.original {
            InspectionPane(
              title: "原文 · 提交时的副本", url: original, scale: scale,
              initialPage: request.page, controller: session.original)
          }
          if let result = snapshot.result {
            InspectionPane(
              title: "处理结果", url: result, scale: scale,
              initialPage: request.page, controller: session.result)
          } else if !snapshot.issues.isEmpty {
            issueList(snapshot.issues)
              .frame(minWidth: 240, idealWidth: 285, maxWidth: 330)
          }
        }
      } else if let error {
        ContentUnavailableView(
          "无法打开文档", systemImage: "exclamationmark.triangle", description: Text(error))
      } else {
        ProgressView("正在校验并准备文档")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .background(TransallTheme.paper)
    .foregroundStyle(TransallTheme.ink)
    .frame(
      minWidth: 760, idealWidth: 1120, maxWidth: .infinity,
      minHeight: 560, idealHeight: 760, maxHeight: .infinity
    )
    .task(id: request.jobID) {
      do {
        let files = try await backend.inspectionSnapshot(jobID: request.jobID)
        guard !Task.isCancelled else {
          try? FileManager.default.removeItem(at: files.directory)
          return
        }
        snapshot = files
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
    }
    .onChange(of: compare) { _, visible in session.comparisonVisible = visible }
    .onChange(of: session.original.pageCount) { _, count in
      if count > 0 { selectInitialIssue() }
    }
    .onDisappear(perform: removeSnapshot)
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) {
      _ in
      removeSnapshot()
    }
  }

  private func issueList(_ issues: [TranslationLayoutIssue]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("需调整的区域 · \(issues.count)").font(.caption.weight(.semibold)).padding(12)
      Divider()
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(issues, id: \.id) { issue in
            Button {
              selectedIssueID = issue.id
              session.original.highlight(issue)
            } label: {
              VStack(alignment: .leading, spacing: 6) {
                Text("第 \(issue.pageIndex + 1) 页").font(.caption.weight(.semibold))
                Text("原文").font(.caption2.weight(.semibold)).foregroundStyle(TransallTheme.muted)
                Text(issue.sourceText).font(.caption)
                  .lineLimit(selectedIssueID == issue.id ? nil : 3)
                  .foregroundStyle(TransallTheme.inkSoft)
                Text("译文").font(.caption2.weight(.semibold)).foregroundStyle(TransallTheme.muted)
                Text(issue.translatedText).font(.callout)
                  .lineLimit(selectedIssueID == issue.id ? nil : 6)
              }
              .frame(maxWidth: .infinity, alignment: .leading).padding(12)
              .background(selectedIssueID == issue.id ? TransallTheme.paper : TransallTheme.panel)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在原文中定位此区域")
            Divider()
          }
        }
      }
    }
    .background(TransallTheme.panel)
  }

  private func selectInitialIssue() {
    guard selectedIssueID == nil, let snapshot, snapshot.result == nil,
      let issue = snapshot.issues.first(where: { $0.pageIndex + 1 == request.page })
        ?? snapshot.issues.first
    else { return }
    selectedIssueID = issue.id
    session.original.highlight(issue)
  }

  private func removeSnapshot() {
    session.original.detach()
    session.result.detach()
    if let snapshot { try? FileManager.default.removeItem(at: snapshot.directory) }
    snapshot = nil
  }
}

private struct InspectionPane: View {
  let title: String
  let url: URL
  let scale: CGFloat
  let initialPage: Int
  @ObservedObject var controller: InspectionPDFController
  @State private var pageInput = "1"

  var body: some View {
    VStack(spacing: 0) {
      TransallControlGroup(spacing: 8) {
        VStack(spacing: 8) {
          HStack(spacing: 10) {
            Text(title).font(.caption.weight(.semibold))
              .foregroundStyle(TransallTheme.inkSoft)
            Spacer(minLength: 0)
            TransallGlassBar {
              pageNavigation
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
          }
          TransallGlassBar {
            searchControls
              .padding(.horizontal, 12).padding(.vertical, 9)
          }
        }
      }
      .padding(10)
      if let searchNotice = controller.searchNotice {
        Text(searchNotice).font(.caption).foregroundStyle(TransallTheme.inkSoft)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12).padding(.vertical, 8)
          .background(TransallTheme.panel)
      }
      InspectionPDFView(url: url, scale: scale, initialPage: initialPage, controller: controller)
        .accessibilityLabel(title)
        .overlay {
          if controller.loading {
            ProgressView("正在打开 PDF").padding().background(TransallTheme.paper)
          } else if let error = controller.loadError {
            ContentUnavailableView(
              "无法读取 PDF", systemImage: "doc.badge.exclamationmark", description: Text(error))
          }
        }
    }
    .background(Color(nsColor: .underPageBackgroundColor))
    .onChange(of: controller.currentPage) { _, page in pageInput = String(page) }
  }

  private var pageNavigation: some View {
    HStack(spacing: 8) {
      Button("上一页", systemImage: "chevron.left") {
        controller.go(to: controller.currentPage - 1)
      }
      .labelStyle(.iconOnly).disabled(controller.currentPage <= 1)
      TextField("页码", text: $pageInput).frame(width: 40).multilineTextAlignment(.center)
        .textFieldStyle(.plain)
        .onSubmit {
          if let page = InspectionNavigation.pageNumber(pageInput, count: controller.pageCount) {
            controller.go(to: page)
          }
          pageInput = String(controller.currentPage)
        }
        .accessibilityLabel("\(title)页码")
        .help("输入页码后按回车跳转")
        .disabled(controller.pageCount == 0)
      Text("/ \(controller.pageCount)").font(.caption).monospacedDigit().fixedSize()
      Button("下一页", systemImage: "chevron.right") {
        controller.go(to: controller.currentPage + 1)
      }
      .labelStyle(.iconOnly).disabled(controller.currentPage >= controller.pageCount)
    }
    .buttonStyle(.borderless)
  }

  private var searchControls: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
      TextField("搜索文档文字", text: $controller.query)
        .textFieldStyle(.plain)
        .onSubmit { controller.moveMatch(forward: true) }
        .accessibilityLabel("搜索\(title)")
      if controller.searching { ProgressView().controlSize(.small) }
      Text(controller.searchSummary).font(.caption).monospacedDigit().fixedSize()
      if !controller.query.isEmpty {
        Button("上一个匹配", systemImage: "chevron.up") { controller.moveMatch(forward: false) }
          .labelStyle(.iconOnly).disabled(controller.matchCount == 0)
          .help("上一个匹配")
        Button("下一个匹配", systemImage: "chevron.down") { controller.moveMatch(forward: true) }
          .labelStyle(.iconOnly).disabled(controller.matchCount == 0)
          .help("下一个匹配")
        Button("清除搜索", systemImage: "xmark") { controller.query = "" }
          .labelStyle(.iconOnly).help("清除搜索")
      }
    }
    .buttonStyle(.borderless)
  }
}

struct InspectionLocation: Equatable {
  let pageIndex: Int
  let x: CGFloat
  let y: CGFloat
}

enum InspectionNavigation {
  static func pageNumber(_ input: String, count: Int) -> Int? {
    guard let value = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)),
      (1...max(1, count)).contains(value), count > 0
    else { return nil }
    return value
  }

  static func canSynchronize(_ firstCount: Int, _ secondCount: Int) -> Bool {
    firstCount > 0 && firstCount == secondCount
  }

  static func location(pageIndex: Int, point: CGPoint, bounds: CGRect) -> InspectionLocation? {
    guard pageIndex >= 0, bounds.width > 0, bounds.height > 0,
      point.x.isFinite, point.y.isFinite
    else { return nil }
    return InspectionLocation(
      pageIndex: pageIndex,
      x: min(1, max(0, (point.x - bounds.minX) / bounds.width)),
      y: min(1, max(0, (point.y - bounds.minY) / bounds.height)))
  }

  static func point(_ location: InspectionLocation, bounds: CGRect) -> CGPoint {
    CGPoint(x: bounds.minX + location.x * bounds.width, y: bounds.minY + location.y * bounds.height)
  }

  static func matchIndex(current: Int?, count: Int, forward: Bool) -> Int? {
    guard count > 0 else { return nil }
    guard let current else { return forward ? 0 : count - 1 }
    return (current + (forward ? 1 : count - 1)) % count
  }
}

@MainActor
private final class InspectionSession: ObservableObject {
  let original = InspectionPDFController()
  let result = InspectionPDFController()
  @Published var synchronize = true
  @Published private var originalCount = 0
  @Published private var resultCount = 0
  var comparisonVisible = true
  private var relaying = false

  var canSynchronize: Bool { InspectionNavigation.canSynchronize(originalCount, resultCount) }
  var pageCountsDiffer: Bool {
    originalCount > 0 && resultCount > 0 && originalCount != resultCount
  }

  init() {
    original.onLoad = { [weak self] count in self?.originalCount = count }
    result.onLoad = { [weak self] count in self?.resultCount = count }
    original.onLocation = { [weak self] location in self?.relay(location, toOriginal: false) }
    result.onLocation = { [weak self] location in self?.relay(location, toOriginal: true) }
  }

  private func relay(_ location: InspectionLocation, toOriginal: Bool) {
    guard synchronize, comparisonVisible, canSynchronize, !relaying else { return }
    relaying = true
    defer { relaying = false }
    (toOriginal ? original : result).receive(location)
  }
}

// The document is constructed off the main thread, then ownership transfers to the main actor.
// No PDFKit object in this box is accessed concurrently.
private struct InspectionLoadedDocument: @unchecked Sendable {
  let document: PDFDocument?
}

@MainActor
final class InspectionPDFController: NSObject, ObservableObject {
  @Published private(set) var currentPage = 1
  @Published private(set) var pageCount = 0
  @Published private(set) var loading = true
  @Published private(set) var loadError: String?
  @Published var query = "" { didSet { scheduleSearch() } }
  @Published private(set) var searching = false
  @Published private(set) var matchCount = 0
  @Published private(set) var matchIndex: Int?
  @Published private(set) var searchNotice: String?
  var onLoad: ((Int) -> Void)?
  var onLocation: ((InspectionLocation) -> Void)?
  private weak var view: PDFView?
  private var loadTask: Task<Void, Never>?
  private var searchTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var matches: [PDFSelection] = []
  private var highlightAnnotation: PDFAnnotation?
  private var pendingIssue: TranslationLayoutIssue?
  private var relaySuppressedUntil: TimeInterval = 0
  private var lastScale: CGFloat?
  static let maximumMatches = 2_000

  var searchSummary: String {
    guard !query.isEmpty else { return "" }
    if let matchIndex { return "\(matchIndex + 1) / \(matchCount)" }
    return searching ? "搜索中" : "\(matchCount) 处"
  }

  func attach(to view: PDFView, url: URL, initialPage: Int) {
    detach()
    self.view = view
    loading = true
    loadError = nil
    loadTask = Task { [weak self, weak view] in
      let loaded = await Task.detached(priority: .userInitiated) {
        InspectionLoadedDocument(document: PDFDocument(url: url))
      }.value
      guard let self, let view, !Task.isCancelled else { return }
      guard let document = loaded.document, document.pageCount > 0 else {
        self.loading = false
        self.loadError = "文件没有可读取的页面。"
        return
      }
      view.document = document
      view.autoScales = true
      self.pageCount = document.pageCount
      self.loading = false
      self.onLoad?(document.pageCount)
      NotificationCenter.default.addObserver(
        self, selector: #selector(self.positionChanged), name: .PDFViewPageChanged, object: view)
      if let clip = view.documentView?.enclosingScrollView?.contentView {
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
          self, selector: #selector(self.positionChanged), name: NSView.boundsDidChangeNotification,
          object: clip)
      }
      self.go(to: min(document.pageCount, max(1, initialPage)))
      if let issue = self.pendingIssue { self.highlight(issue) }
      self.scheduleSearch()
    }
  }

  func detach() {
    loadTask?.cancel()
    loadTask = nil
    stopSearch()
    NotificationCenter.default.removeObserver(self)
    if let highlightAnnotation { highlightAnnotation.page?.removeAnnotation(highlightAnnotation) }
    highlightAnnotation = nil
    pendingIssue = nil
    view?.document = nil
    view = nil
    pageCount = 0
    onLoad?(0)
    lastScale = nil
  }

  func setScale(_ scale: CGFloat) {
    guard let view, view.document != nil, lastScale != scale else { return }
    lastScale = scale
    view.autoScales = scale == 1
    if scale != 1 { view.scaleFactor = view.scaleFactorForSizeToFit * scale }
  }

  func go(to pageNumber: Int) {
    guard let view, let page = view.document?.page(at: pageNumber - 1) else { return }
    view.go(to: page)
    updatePosition()
  }

  func highlight(_ issue: TranslationLayoutIssue) {
    pendingIssue = issue
    guard let view, let page = view.document?.page(at: issue.pageIndex) else { return }
    if let highlightAnnotation { highlightAnnotation.page?.removeAnnotation(highlightAnnotation) }
    let annotation = PDFAnnotation(bounds: issue.bounds, forType: .square, withProperties: nil)
    annotation.color = NSColor.systemOrange
    annotation.interiorColor = NSColor.systemOrange.withAlphaComponent(0.14)
    let border = PDFBorder()
    border.lineWidth = 2
    annotation.border = border
    page.addAnnotation(annotation)
    highlightAnnotation = annotation
    view.go(to: page)
    let visibleIssue = view.convert(issue.bounds, from: page)
    if !view.bounds.contains(visibleIssue) {
      // Keep the surrounding content on screen when zoomed in. PDFKit performs both
      // coordinate conversions, including crop offsets and rotated pages.
      let visiblePage = view.convert(page.bounds(for: .cropBox), from: page)
      let context = visibleIssue.insetBy(dx: -32, dy: -view.bounds.height * 0.6)
        .intersection(visiblePage)
      if !context.isNull {
        view.go(to: view.convert(context, to: page), on: page)
      }
    }
    updatePosition()
  }

  func receive(_ location: InspectionLocation) {
    guard let view, let page = view.document?.page(at: location.pageIndex) else { return }
    // PDFKit can deliver bounds notifications after go(to:) returns. Suppress those as well
    // as synchronous notifications so the receiving pane cannot send the scroll back.
    relaySuppressedUntil = ProcessInfo.processInfo.systemUptime + 0.1
    view.go(
      to: PDFDestination(
        page: page, at: InspectionNavigation.point(location, bounds: page.bounds(for: .cropBox))))
    updatePosition()
  }

  @objc private func positionChanged(_ notification: Notification) { updatePosition() }

  private func updatePosition() {
    guard let view, let document = view.document else { return }
    // In continuous mode, currentPage may follow the current text selection in one
    // pane and a partially visible page in the other. Use the same visible position
    // in both panes so an original without a selection reports the matching page.
    let center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    guard let page = view.page(for: center, nearest: true) ?? view.currentPage else { return }
    currentPage = document.index(for: page) + 1
    guard ProcessInfo.processInfo.systemUptime >= relaySuppressedUntil,
      let destination = view.currentDestination, let destinationPage = destination.page,
      let location = InspectionNavigation.location(
        pageIndex: document.index(for: destinationPage), point: destination.point,
        bounds: destinationPage.bounds(for: .cropBox))
    else { return }
    onLocation?(location)
  }

  private func scheduleSearch() {
    stopSearch()
    guard let document = view?.document else { return }
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    guard text.count <= 256 else {
      searchNotice = "搜索文字最多 256 个字符，请缩短关键词。"
      return
    }
    searching = true
    searchTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
      guard let self, !Task.isCancelled, self.view?.document === document else { return }
      NotificationCenter.default.addObserver(
        self, selector: #selector(self.foundMatch), name: .PDFDocumentDidFindMatch, object: document
      )
      NotificationCenter.default.addObserver(
        self, selector: #selector(self.searchEnded), name: .PDFDocumentDidEndFind, object: document)
      document.beginFindString(text, withOptions: [.caseInsensitive, .diacriticInsensitive])
      self.timeoutTask = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(8)) } catch { return }
        guard let self, self.searching else { return }
        self.finishLimitedSearch("搜索超过 8 秒，已暂停。当前显示已找到的匹配；可用更具体的关键词继续。")
      }
    }
  }

  private func stopSearch() {
    searchTask?.cancel()
    timeoutTask?.cancel()
    searchTask = nil
    timeoutTask = nil
    searching = false
    if let document = view?.document {
      NotificationCenter.default.removeObserver(
        self, name: .PDFDocumentDidFindMatch, object: document)
      NotificationCenter.default.removeObserver(
        self, name: .PDFDocumentDidEndFind, object: document)
      document.cancelFindString()
    }
    matches = []
    matchCount = 0
    matchIndex = nil
    searchNotice = nil
    view?.clearSelection()
  }

  @objc private func foundMatch(_ notification: Notification) {
    guard searching, let document = notification.object as? PDFDocument,
      document === view?.document,
      let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection
    else { return }
    matches.append(selection)
    matchCount = matches.count
    if matchIndex == nil { showMatch(at: 0) }
    if matches.count >= Self.maximumMatches {
      finishLimitedSearch("已显示前 2,000 处匹配。请用更具体的关键词缩小范围。")
    }
  }

  @objc private func searchEnded(_ notification: Notification) {
    searching = false
    timeoutTask?.cancel()
  }

  private func finishLimitedSearch(_ notice: String) {
    searching = false
    searchNotice = notice
    view?.document?.cancelFindString()
  }

  func moveMatch(forward: Bool) {
    guard
      let index = InspectionNavigation.matchIndex(
        current: matchIndex, count: matches.count, forward: forward)
    else { return }
    showMatch(at: index)
  }

  private func showMatch(at index: Int) {
    guard matches.indices.contains(index), let view else { return }
    matchIndex = index
    view.setCurrentSelection(matches[index], animate: false)
    view.scrollSelectionToVisible(nil)
    updatePosition()
  }
}

private struct InspectionPDFView: NSViewRepresentable {
  let url: URL
  let scale: CGFloat
  let initialPage: Int
  let controller: InspectionPDFController

  func makeCoordinator() -> InspectionPDFController { controller }

  func makeNSView(context: Context) -> PDFView {
    let view = PDFView()
    view.displayMode = .singlePageContinuous
    view.displayDirection = .vertical
    view.backgroundColor = .underPageBackgroundColor
    controller.attach(to: view, url: url, initialPage: initialPage)
    return view
  }

  func updateNSView(_ view: PDFView, context: Context) { controller.setScale(scale) }

  static func dismantleNSView(_ view: PDFView, coordinator: InspectionPDFController) {
    coordinator.detach()
  }
}
