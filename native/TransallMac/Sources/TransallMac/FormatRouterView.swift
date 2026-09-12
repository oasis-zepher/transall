import SwiftUI
import UniformTypeIdentifiers

enum WorkbenchTask: String, CaseIterable, Identifiable {
  case editPDF, translatePDF, recognizeText, extractMarkdown, createPDF

  var id: Self { self }
  var title: String {
    switch self {
    case .editPDF: "整理 PDF"
    case .translatePDF: "翻译 PDF"
    case .recognizeText: "识别文字"
    case .extractMarkdown: "提取 Markdown"
    case .createPDF: "生成 PDF"
    }
  }
  var symbol: String {
    switch self {
    case .editPDF: "doc.on.doc"
    case .translatePDF: "character.bubble"
    case .recognizeText: "text.viewfinder"
    case .extractMarkdown: "text.document"
    case .createPDF: "doc.badge.plus"
    }
  }
  var sources: [String] {
    switch self {
    case .editPDF, .translatePDF: ["pdf"]
    case .recognizeText: ["pdf", "image"]
    case .extractMarkdown: ["pdf", "image", "word", "ppt", "excel", "html", "data"]
    case .createPDF: ["image", "word", "ppt", "excel", "md", "html", "data"]
    }
  }
  var target: String {
    switch self {
    case .editPDF, .createPDF: "pdf"
    case .translatePDF: "translated_pdf"
    case .recognizeText: "ocr"
    case .extractMarkdown: "md"
    }
  }
  func selection(source: String? = nil) -> RouteSelection {
    RouteSelection(
      source: source.flatMap { sources.contains($0) ? $0 : nil } ?? sources[0], target: target)
  }
  static func matching(_ selection: RouteSelection) -> Self? {
    allCases.first { $0.target == selection.target && $0.sources.contains(selection.source ?? "") }
  }
  static func sourceTitle(_ source: String) -> String {
    switch source {
    case "word": "Word"
    case "ppt": "PPT"
    case "excel": "Excel"
    case "pdf": "PDF"
    case "image": "图片"
    case "md": "Markdown"
    case "html": "HTML"
    case "data": "文本数据"
    default: source
    }
  }
  static func contentTypes(source: String?) -> [UTType] {
    let extensions =
      NativeCapabilities.routes.first { $0.source == source }?.accept
      .split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ".", with: "")
      } ?? []
    return extensions.compactMap { UTType(filenameExtension: $0) }
  }
}

enum NativeFormatOrbit {
  static func moduleDiameter(size: CGFloat) -> CGFloat { min(88, floor(size * 0.14) - 1) }
  static let formats = [
    "pdf", "translated_pdf", "ocr", "md", "html", "image", "data", "word", "ppt", "excel",
  ]

  static func remainingFormats(
    for selection: RouteSelection, lifting format: String? = nil,
    order: [String] = NativeFormatOrbit.formats
  )
    -> [String]
  {
    order.filter { $0 != selection.source && $0 != selection.target && $0 != format }
  }

  static func angle(of format: String, among remaining: [String]) -> Double {
    let index = remaining.firstIndex(of: format) ?? 0
    return Double(index) / Double(max(1, remaining.count)) * .pi * 2 - .pi / 2
  }

  static func nearestAngle(_ angle: Double, to reference: Double) -> Double {
    reference + atan2(sin(angle - reference), cos(angle - reference))
  }

  static func candidateSlots(for selection: RouteSelection, activeSlot: FormatRouteSlot)
    -> [FormatRouteSlot]
  {
    if selection.source == nil && selection.target == nil { return [.source, .target] }
    return [activeSlot]
  }

  // Strength grows continuously as the pointer approaches an empty slot, without a hard jump.
  static func dockingStrength(at point: CGPoint, to frame: CGRect, reach: CGFloat = 64) -> CGFloat {
    let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
    let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
    let distance = hypot(dx, dy)
    let proximity = max(0, min(1, 1 - distance / max(1, reach)))
    return proximity * proximity * (3 - 2 * proximity)
  }

  // Entering through the narrow waist takes progress through the chamber, instead of
  // becoming fully stretched as soon as the pointer crosses its rectangular hit edge.
  static func dockingStrength(at point: CGPoint, to frame: CGRect, slot: FormatRouteSlot) -> CGFloat
  {
    let base = dockingStrength(at: point, to: frame)
    let throughWaist = slot == .source ? point.y > frame.midY : point.y < frame.midY
    guard throughWaist else { return base }
    let distance = slot == .source ? frame.maxY + 64 - point.y : point.y - frame.minY + 64
    let t = min(1, max(0, distance / (64 + frame.height / 2)))
    let eased = t * t * (3 - 2 * t)
    return base * eased * eased
  }

  static func title(_ format: String) -> String {
    switch format {
    case "translated_pdf": "译文 PDF"
    case "ocr": "OCR"
    default: WorkbenchTask.sourceTitle(format)
    }
  }

  static func symbol(_ format: String) -> String {
    switch format {
    case "word": "doc.text"
    case "ppt": "rectangle.on.rectangle"
    case "excel": "tablecells"
    case "pdf": "doc.richtext"
    case "translated_pdf": "character.bubble"
    case "ocr": "text.viewfinder"
    case "md": "doc.plaintext"
    case "html": "chevron.left.forwardslash.chevron.right"
    case "image": "photo"
    default: "doc.text"
    }
  }
}

private struct OrbitDrag {
  let id = UUID()
  let format: String
  let origin: FormatRouteSlot?
  let selection: RouteSelection
  let home: CGPoint
  let ringBefore: [String]
  let orbitSize: CGFloat
  var position: CGPoint
  var hoveredSlot: FormatRouteSlot?
  var docking: OrbitDockingTarget?
  var settling = false
  var cancellationRequested = false
  var settlingStart: CGPoint?
  var settleProgress = 0.0
  var settlingSelection: RouteSelection?
  var returnPlan: OrbitReturnPlan?
}

// Interpolating the angle keeps a redistributing module on the rim instead of cutting across it.
private struct OrbitArcPlacement: AnimatableModifier {
  nonisolated var angle: Double
  nonisolated var size: CGFloat

  nonisolated var animatableData: AnimatablePair<Double, CGFloat> {
    get { AnimatablePair(angle, size) }
    set {
      angle = newValue.first
      size = newValue.second
    }
  }

  func body(content: Content) -> some View {
    content.position(
      x: size / 2 + cos(angle) * size * 0.385,
      y: size / 2 + sin(angle) * size * 0.385)
  }
}

// Keep each module's angular coordinate continuous across the top-of-ring seam.
private struct OrbitPlacement: ViewModifier {
  let angle: Double
  let size: CGFloat
  let animation: Animation?
  let visible: Bool
  @State private var continuousAngle: Double
  @State private var wasVisible: Bool

  init(angle: Double, size: CGFloat, animation: Animation?, visible: Bool) {
    self.angle = angle
    self.size = size
    self.animation = animation
    self.visible = visible
    _continuousAngle = State(initialValue: angle)
    _wasVisible = State(initialValue: visible)
  }

  func body(content: Content) -> some View {
    // A newly revealed host must already be at the drag/extrusion endpoint on its
    // first frame. Never expose the tail of its own independent ring animation.
    content.modifier(
      OrbitArcPlacement(angle: visible && wasVisible ? continuousAngle : angle, size: size)
    )
    .transaction {
      if !visible || !wasVisible {
        $0.animation = nil
        $0.disablesAnimations = true
      }
    }
    .onChange(of: angle) { _, next in
      if visible && wasVisible {
        withAnimation(animation) {
          continuousAngle = NativeFormatOrbit.nearestAngle(next, to: continuousAngle)
        }
      } else {
        alignHiddenHost()
      }
    }
    .onChange(of: visible) { _, _ in alignHiddenHost() }
  }

  private func alignHiddenHost() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      continuousAngle = NativeFormatOrbit.nearestAngle(angle, to: continuousAngle)
      wasVisible = visible
    }
  }
}

struct FormatRouterView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var drag: OrbitDrag?
  @State private var activeSlot: FormatRouteSlot = .source
  @State private var ignoreClickUntil = Date.distantPast
  @State private var selectionHint: String?
  @State private var flip: HourglassFlipPresentation?
  @State private var flipAngle = 0.0
  @Binding var ringOrder: [String]
  @State private var pendingReturn: OrbitReturnPlan?
  @State private var committedRingOrder: [String]?
  @State private var preparedRingPlan: OrbitReturnPlan?
  @State private var departures: [OrbitReleasedFormat] = []
  @State private var departureID = UUID()
  @State private var releasePresentations: [String: OrbitReleasePresentation] = [:]
  @State private var clearanceFormats: Set<String> = []
  @State private var clearanceTokens: [String: UUID] = [:]

  private var motion: Animation? { reduceMotion ? nil : .easeOut(duration: 0.24) }
  private var orbitMotion: Animation? {
    reduceMotion ? nil : .timingCurve(0.22, 1, 0.36, 1, duration: 0.48)
  }
  private var ringFormats: [String] {
    if let plan = drag?.returnPlan {
      return NativeFormatOrbit.remainingFormats(for: plan.after, order: plan.order)
    }
    if let plan = preparedRingPlan {
      return NativeFormatOrbit.remainingFormats(for: plan.after, order: plan.order)
    }
    return NativeFormatOrbit.remainingFormats(
      for: drag?.settlingSelection ?? model.selection,
      lifting: drag?.settling == false ? drag?.format : nil,
      order: committedRingOrder ?? ringOrder)
  }
  private var rolePreview: RouteSelection? {
    guard let drag else { return nil }
    if drag.settling { return drag.settlingSelection }
    return model.orbitPreviewSelection(
      for: drag.format, from: drag.origin, docking: drag.docking)
  }

  private var rolePreviewAmount: Double {
    guard rolePreview != nil, let drag else { return 0 }
    if reduceMotion || drag.settling { return 1 }
    return Double(drag.docking?.strength ?? 0)
  }

  private var isAnimatingSelection: Bool { flip != nil || !departures.isEmpty }
  private var acceptsClick: Bool {
    drag == nil && !isAnimatingSelection && Date.now >= ignoreClickUntil
  }

  var body: some View {
    GeometryReader { proxy in
      let size = max(300, min(580, proxy.size.width - 48, proxy.size.height - 180))
      VStack(spacing: 18) {
        VStack(spacing: 6) {
          Text(model.route?.title ?? "选择转换格式")
            .font(.system(size: 26, weight: .semibold))
          Text(instruction).font(.callout).foregroundStyle(.secondary)
            .contentTransition(.opacity)
        }
        orbit(size: size)
          .frame(width: size, height: size)
        HStack(spacing: 16) {
          if model.route != nil {
            Button("选择文件…", systemImage: "plus") {
              NotificationCenter.default.post(name: .transallChooseDocuments, object: nil)
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(
              !model.canSelectDocuments || drag != nil || isAnimatingSelection
            )
            .transition(.opacity)
          }
        }
        .frame(height: 36)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .onChange(of: model.selection) { previous, selection in
        selectionDidChange(from: previous, to: selection, size: size)
      }
      .onChange(of: ringOrder) { _, order in
        if committedRingOrder == order { committedRingOrder = nil }
      }
      .onChange(of: proxy.size) { _, _ in
        drag = nil
        cancelFlip()
        if departures.isEmpty { cancelDepartures() }
      }
    }
    .background(TransallTheme.paper)
    .onExitCommand {
      cancelDrag()
      cancelFlip()
    }
    .onDisappear {
      drag = nil
      cancelFlip()
      cancelDepartures()
      pendingReturn = nil
    }
    .onChange(of: reduceMotion) { _, _ in
      drag = nil
      cancelFlip()
      cancelDepartures()
    }
    .onChange(of: model.canChangeRoute) { _, allowed in
      if !allowed {
        drag = nil
        cancelFlip()
        cancelDepartures()
      }
    }
  }

  private var instruction: String {
    if let lock = model.routeChangeLock { return lock.helpText }
    if let drag, !drag.settling {
      if let docking = drag.docking, docking.compatibility == .incompatible {
        return "不能用作\(docking.slot.title)，松手返回"
      }
      if let slot = drag.hoveredSlot {
        return accepts(drag, in: slot)
          ? "松手放入“\(slot.title)”" : "此组合暂不支持，松手返回"
      }
      if drag.returnPlan != nil { return "松手放回这两个模块之间" }
      return drag.origin == nil ? "拖到中央槽位，松手放入" : "拖到外圈两个模块之间，按 Esc 取消"
    }
    if let selectionHint { return selectionHint }
    return "上半部：源格式 · 下半部：输出格式 · 与空槽同色表示支持"
  }

  private func homePosition(
    _ format: String, among formats: [String], size: CGFloat, phase: Double = 0
  ) -> CGPoint {
    let angle = NativeFormatOrbit.angle(of: format, among: formats) + phase
    return CGPoint(
      x: size / 2 + cos(angle) * size * 0.385,
      y: size / 2 + sin(angle) * size * 0.385)
  }

  private func slotFrame(_ slot: FormatRouteSlot, size: CGFloat) -> CGRect {
    HourglassLayout(orbitSize: size).slotFrame(slot)
  }

  private func orbit(size: CGFloat) -> some View {
    let diameter = NativeFormatOrbit.moduleDiameter(size: size)
    let remaining = ringFormats
    let outlets = Set(clearanceFormats.compactMap { releasePresentations[$0]?.item.slot })
    let hidden = Set(
      departures.map(\.format) + (drag.map { [$0.format] } ?? [])
        + (drag?.returnPlan?.departures.map(\.format) ?? [])
        + (preparedRingPlan?.departures.map(\.format) ?? []))
    let phase = OrbitExitClearance.phase(
      formats: remaining, hidden: hidden, slots: outlets, size: size)
    return ZStack {
      TransallControlGroup(spacing: 14) {
        ZStack {
          Circle().fill(TransallTheme.panel)
            .overlay {
              Circle().stroke(
                contrast == .increased ? TransallTheme.inkSoft : TransallTheme.line, lineWidth: 1)
            }
            .accessibilityHidden(true)
          Circle().stroke(TransallTheme.line, lineWidth: 1)
            .frame(width: size * 0.77, height: size * 0.77)
            .position(x: size / 2, y: size / 2)
            .accessibilityHidden(true)
          ForEach(NativeFormatOrbit.formats, id: \.self) { format in
            let home = homePosition(format, among: remaining, size: size, phase: phase)
            let lifting = drag?.format == format && drag?.origin == nil && drag?.settling == false
            let leaving =
              departures.contains { $0.format == format }
              || drag?.returnPlan?.departures.contains { $0.format == format } == true
              || preparedRingPlan?.departures.contains { $0.format == format } == true
            let visible = remaining.contains(format) && drag?.format != format && !leaving
            let roles = model.orbitRoles(for: format, selection: rolePreview)
            // Retain the lifted button's gesture host until mouse-up even though it is invisible.
            let angle =
              lifting
              ? NativeFormatOrbit.angle(
                of: format,
                among: drag?.ringBefore ?? remaining)
              : NativeFormatOrbit.angle(of: format, among: remaining)
            Button {
              select(format)
            } label: {
              Color.clear.frame(width: diameter, height: diameter).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canChangeRoute || isAnimatingSelection)
            .accessibilityLabel(NativeFormatOrbit.title(format))
            .accessibilityValue(roles.description)
            .help(roles.description)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(visible || lifting)
            .accessibilityHidden(!visible)
            .simultaneousGesture(moduleDrag(format, from: nil, home: home, size: size))
            .contextMenu {
              ForEach(FormatRouteSlot.allCases, id: \.self) { slot in
                Button("用作\(slot.title)") { assign(format, to: slot) }
                  .disabled(
                    !model.orbitDestinations(for: format, activeSlot: activeSlot).contains(slot))
              }
            }
            .accessibilityAction(named: "用作源格式") {
              if model.orbitDestinations(for: format, activeSlot: activeSlot).contains(.source) {
                assign(format, to: .source)
              }
            }
            .accessibilityAction(named: "用作目标格式") {
              if model.orbitDestinations(for: format, activeSlot: activeSlot).contains(.target) {
                assign(format, to: .target)
              }
            }
            .modifier(
              OrbitPlacement(
                angle: angle + phase, size: size, animation: orbitMotion, visible: visible))
          }
          hourglass(size: size)
        }
      }
      ForEach(NativeFormatOrbit.formats, id: \.self) { format in
        let current = drag?.format == format ? drag : nil
        let leaving = hidden.contains(format) && current == nil
        OrbitStableModule(
          format: format, size: size,
          angle: NativeFormatOrbit.angle(of: format, among: remaining) + phase,
          visible: current != nil || (remaining.contains(format) && !leaving),
          motion: current.map {
            OrbitModuleMotion(
              docking: $0.docking, settling: $0.settling,
              progress: $0.settling ? $0.settleProgress : 0,
              anchor: $0.settlingStart ?? $0.position, destination: $0.position,
              arrivalRoles: model.orbitRoles(for: format, selection: $0.settlingSelection))
          },
          roles: model.orbitRoles(for: format),
          previewRoles: model.orbitRoles(for: format, selection: rolePreview),
          previewAmount: rolePreviewAmount
        )
        .allowsHitTesting(false).accessibilityHidden(true)
        .zIndex(current == nil ? 0 : 10)
      }
      // Stable identities span approach, retraction and committed departure.
      departureLayer(size: size, diameter: diameter, phase: phase)
        .onChange(of: departureID) { _, _ in animateDepartures() }
    }
    .coordinateSpace(name: "formatOrbit")
    .accessibilityElement(children: .contain)
    .accessibilityLabel("格式转盘")
  }

  private func hourglass(size: CGFloat) -> some View {
    let layout = HourglassLayout(orbitSize: size)
    return ZStack {
      ZStack {
        ForEach(FormatRouteSlot.allCases, id: \.self) { slot in
          let rect = layout.slotFrame(slot)
          let chamber = layout.chamberFrame(slot)
          OrbitModuleShape(slot: slot, amount: 1)
            .fill(isHovered(slot) ? TransallTheme.accentSoft : .clear)
            .frame(width: chamber.width, height: chamber.height)
            .position(x: chamber.midX - layout.frame.minX, y: chamber.midY - layout.frame.minY)
            .animation(motion, value: isHovered(slot))
            .allowsHitTesting(false).accessibilityHidden(true)
          slotView(slot, size: size)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX - layout.frame.minX, y: rect.midY - layout.frame.minY)
        }
        if let flip {
          ForEach(FormatRouteSlot.allCases, id: \.self) { slot in
            if let format = flip.selection[slot] {
              formatLabel(format)
                .frame(width: layout.frame.width * 0.78)
                .modifier(
                  HourglassFlipPlacement(
                    angle: flipAngle, slot: slot,
                    center: CGPoint(x: layout.frame.width / 2, y: layout.frame.height / 2))
                )
                .allowsHitTesting(false).accessibilityHidden(true)
            }
          }
        }
      }
      .frame(width: layout.frame.width, height: layout.frame.height)
      .modifier(HourglassSurface(rotation: flipAngle))
      .position(x: layout.frame.midX, y: layout.frame.midY)
      Button("倒转", systemImage: "arrow.triangle.2.circlepath") { reverseFormats() }
        .labelStyle(.iconOnly).buttonStyle(QuietButtonStyle()).buttonBorderShape(.circle)
        .frame(width: 32, height: 32)
        .disabled(flipDisabledReason != nil)
        .help(flipDisabledReason ?? "交换源格式与目标格式")
        .accessibilityLabel("倒转：交换源格式与目标格式")
        .accessibilityHint(flipDisabledReason ?? "交换后重新选择输入文件")
        .position(layout.flipCenter)
      Button("清空", systemImage: "xmark") {
        guard acceptsClick, model.canChangeRoute else { return }
        model.resetFormatSelection()
      }
      .labelStyle(.iconOnly).buttonStyle(QuietButtonStyle()).buttonBorderShape(.circle)
      .frame(width: 32, height: 32)
      .disabled(
        drag != nil || isAnimatingSelection || !model.canChangeRoute
          || model.selection == RouteSelection()
      )
      .help("清空源格式与目标格式，将模块放回外圈")
      .accessibilityLabel("清空源格式与目标格式")
      .position(layout.clearCenter)
    }
  }

  private func formatLabel(_ format: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: NativeFormatOrbit.symbol(format))
      Text(NativeFormatOrbit.title(format)).lineLimit(1).minimumScaleFactor(0.8)
    }
    .font(.headline).foregroundStyle(TransallTheme.accent)
  }

  private func isHovered(_ slot: FormatRouteSlot) -> Bool {
    (drag?.hoveredSlot == slot || drag?.docking?.slot == slot)
      && drag.map { accepts($0, in: slot) } == true
  }

  private func slotView(_ slot: FormatRouteSlot, size: CGFloat) -> some View {
    let format = model.selection[slot]
    let rect = slotFrame(slot, size: size)
    let otherSlot: FormatRouteSlot = slot == .source ? .target : .source
    let reusePDF = format == nil && model.selection[otherSlot] == "pdf"
    return Button {
      guard acceptsClick else { return }
      if reusePDF {
        assign("pdf", to: slot)
        return
      }
      activeSlot = slot
      selectionHint = "请选择\(slot.title)，也可拖入模块"
    } label: {
      VStack(spacing: 5) {
        Text(slot.title).font(.caption)
          .foregroundStyle(activeSlot == slot ? TransallTheme.accent : TransallTheme.inkSoft)
        Group {
          if let format {
            formatLabel(format)
          } else {
            Text(reusePDF ? "整理 PDF" : "拖入模块").font(.headline).foregroundStyle(.secondary)
          }
        }
        .frame(width: rect.width * 0.78)
        .opacity(
          flip != nil
            ? 0
            : (drag?.origin == slot
              ? 0.2
              : (drag?.docking?.slot == slot && drag?.docking?.compatibility == .compatible
                ? 1 - (drag?.docking?.strength ?? 0) : 1)))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipShape(HourglassChamberShape(slot: slot))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain).disabled(!model.canChangeRoute || isAnimatingSelection)
    .simultaneousGesture(
      moduleDrag(
        format, from: slot,
        home: CGPoint(x: rect.midX, y: rect.midY), size: size)
    )
    .contextMenu {
      if let format { Button("移除\(slot.title)") { remove(format, from: slot) } }
    }
    .accessibilityLabel("\(slot.title)：\(format.map(NativeFormatOrbit.title) ?? "未选择")")
    .accessibilityHint(reusePDF ? "点击以整理 PDF，或拖入其他\(slot.title)" : "点击后选择格式，或将格式模块拖入此处")
    .accessibilityAction(named: "移除格式") { if let format { remove(format, from: slot) } }
    .help(
      reusePDF
        ? "点击以整理 PDF，或拖入其他\(slot.title)" : (format == nil ? "拖入模块，或点击后选择格式" : "拖出以移除，或使用翻转按钮交换"))
  }

  private var flipDisabledReason: String? {
    if flip != nil { return "正在交换格式" }
    if drag != nil { return "请先结束拖动" }
    if !departures.isEmpty { return "正在将模块放回外圈" }
    return model.formatReversalDisabledReason
  }

  private func reverseFormats() {
    guard acceptsClick, flipDisabledReason == nil else { return }
    let presentation = HourglassFlipPresentation(selection: model.selection)
    flip = presentation
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.42), completionCriteria: .removed) {
      flipAngle = 180
    } completion: {
      guard flip?.id == presentation.id else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        _ = model.reverseFormats(expectedSelection: presentation.selection)
        flip = nil
        flipAngle = 0
      }
    }
  }

  private func cancelFlip() {
    guard flip != nil else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      flip = nil
      flipAngle = 0
    }
  }

  private func moduleDrag(
    _ format: String?, from origin: FormatRouteSlot?, home: CGPoint,
    size: CGFloat
  ) -> some Gesture {
    DragGesture(minimumDistance: 5, coordinateSpace: .named("formatOrbit"))
      .onChanged { value in
        guard let format, model.canChangeRoute, !isAnimatingSelection else { return }
        if drag == nil {
          selectionHint = nil
          drag = OrbitDrag(
            format: format, origin: origin, selection: model.selection,
            home: home, ringBefore: ringFormats, orbitSize: size,
            position: home)
        }
        guard drag?.settling == false, drag?.format == format, drag?.origin == origin else {
          return
        }
        // Preserve the pickup offset so the module does not jump to the cursor.
        let anchor = drag?.home ?? home
        drag?.position = CGPoint(
          x: anchor.x + value.translation.width,
          y: anchor.y + value.translation.height)
        drag?.hoveredSlot = HourglassLayout(orbitSize: size).slot(at: value.location)
        if let current = drag {
          drag?.docking = dockingTarget(for: current, at: value.location, size: size)
          drag?.returnPlan = returnPlan(for: current, at: value.location, size: size, nearRim: true)
          updatePreparedReleases(for: current, docking: drag?.docking)
        }
      }
      .onEnded { value in
        guard let current = drag, !current.settling else { return }
        // Native buttons may also receive mouse-up when Reduce Motion finishes immediately.
        ignoreClickUntil = .now.addingTimeInterval(0.35)
        let destination = HourglassLayout(orbitSize: size).slot(at: value.location)
        let next = model.orbitDropSelection(
          for: current.format, from: current.origin, at: value.location,
          layout: HourglassLayout(orbitSize: size))
        let accepted = next != nil
        let plan = next.map {
          OrbitReturnPlan.make(
            before: current.selection, after: $0, order: ringOrder,
            draggedFormat: destination == nil ? current.format : nil,
            dropPoint: destination == nil ? value.location : nil, size: size)
        }
        let end: CGPoint
        if accepted, let destination {
          let rect = slotFrame(destination, size: size)
          end =
            OrbitDockingTarget(
              slot: destination, frame: rect, strength: 1,
              compatibility: .compatible
            ).presentationCenter
        } else if accepted, let next, let plan {
          if let retained = FormatRouteSlot.allCases.first(where: { next[$0] == current.format }) {
            let rect = slotFrame(retained, size: size)
            end = CGPoint(x: rect.midX, y: rect.midY)
          } else {
            end = homePosition(
              current.format,
              among: NativeFormatOrbit.remainingFormats(for: next, order: plan.order), size: size)
          }
        } else {
          end = current.home
        }
        settle(
          current, at: end, selection: next, plan: plan,
          docking: accepted
            ? destination.map {
              OrbitDockingTarget(
                slot: $0, frame: slotFrame($0, size: size), strength: 1,
                compatibility: .compatible)
            } : nil
        ) {
          if accepted && model.selection == current.selection {
            pendingReturn = plan
            if !model.dropFormat(current.format, from: current.origin, to: destination)
              || model.selection == current.selection
            {
              pendingReturn = nil
            }
          }
        }
      }
  }

  private func accepts(_ drag: OrbitDrag, in slot: FormatRouteSlot?) -> Bool {
    model.formatSelection(dropping: drag.format, from: drag.origin, to: slot) != nil
  }

  private func dockingTarget(for current: OrbitDrag, at point: CGPoint, size: CGFloat)
    -> OrbitDockingTarget?
  {
    model.orbitDockingFeedback(
      for: current.format, from: current.origin, at: point,
      layout: HourglassLayout(orbitSize: size))
  }

  private func settle(
    _ current: OrbitDrag, at point: CGPoint,
    selection: RouteSelection? = nil, plan: OrbitReturnPlan? = nil,
    docking: OrbitDockingTarget? = nil,
    completion: @escaping () -> Void
  ) {
    // Keep the raw anchor; the single animated presentation retains the current morph
    // and attraction at mouse-up while interpolating that anchor toward the destination.
    let start = current.position
    var settling = current
    settling.settling = true
    settling.settlingStart = start
    settling.settleProgress = 0
    settling.position = point
    settling.settlingSelection = selection ?? current.selection
    settling.returnPlan = plan
    drag = settling
    updatePreparedReleases(for: settling, docking: docking)
    let duration =
      docking == nil ? OrbitDragGeometry.ringDuration : OrbitDragGeometry.chamberDuration
    withAnimation(reduceMotion ? nil : .easeOut(duration: duration), completionCriteria: .removed) {
      drag?.settleProgress = 1
      drag?.hoveredSlot = nil
      drag?.docking = docking
    } completion: {
      guard let finished = drag, finished.id == current.id else { return }
      if finished.cancellationRequested {
        var returning = finished
        returning.cancellationRequested = false
        // Finish the current interpolation before reversing it; no guessed presentation
        // position and no stale drop commit when Escape arrives during mouse-up.
        settle(returning, at: current.home) {}
        return
      }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        // Place the hidden ring host at its committed destination before revealing it.
        if let plan, model.selection == current.selection {
          // The parent binding updates on a later render pass. Keep the committed
          // order locally so clearing the drag cannot expose the old ring for one frame.
          committedRingOrder = plan.order
          ringOrder = plan.order
        }
        completion()
        drag = nil
      }
    }
  }

  private func cancelDrag() {
    guard let current = drag else { return }
    ignoreClickUntil = .now.addingTimeInterval(0.35)
    if current.settling {
      drag?.cancellationRequested = true
      return
    }
    // Replace the ID to invalidate any pending drop completion.
    drag = OrbitDrag(
      format: current.format, origin: current.origin,
      selection: current.selection, home: current.home, ringBefore: current.ringBefore,
      orbitSize: current.orbitSize,
      position: current.position, docking: current.docking)
    if let cancelled = drag { settle(cancelled, at: current.home) {} }
  }

  private func returnPlan(for current: OrbitDrag, at point: CGPoint, size: CGFloat, nearRim: Bool)
    -> OrbitReturnPlan?
  {
    guard current.origin != nil,
      !HourglassLayout(orbitSize: size).frame.contains(point),
      !nearRim || hypot(point.x - size / 2, point.y - size / 2) >= size * 0.28,
      let next = model.formatSelection(dropping: current.format, from: current.origin, to: nil),
      next.source != current.format, next.target != current.format
    else { return nil }
    return OrbitReturnPlan.make(
      before: current.selection, after: next,
      order: current.ringBefore
        + NativeFormatOrbit.formats.filter { !current.ringBefore.contains($0) },
      draggedFormat: current.format, dropPoint: point, size: size)
  }

  private func selectionDidChange(
    from before: RouteSelection, to after: RouteSelection, size: CGFloat
  ) {
    if let flip, flip.selection != after { cancelFlip() }
    let plan: OrbitReturnPlan
    if let pendingReturn, pendingReturn.before == before, pendingReturn.after == after {
      plan = pendingReturn
    } else {
      plan = OrbitReturnPlan.make(before: before, after: after, order: ringOrder, size: size)
    }
    pendingReturn = nil
    drag = nil
    committedRingOrder = plan.order
    ringOrder = plan.order
    let prepared = releasePresentations
    cancelDepartures()
    if !reduceMotion, !plan.departures.isEmpty {
      departures = plan.departures
      for item in plan.departures {
        clearanceFormats.insert(item.format)
        let previous = prepared[item.format]
        releasePresentations[item.format] =
          previous?.item == item
          ? previous : OrbitReleasePresentation(item: item, progress: 0)
      }
    }
    selectionHint = nil
    activeSlot = after.source == nil ? .source : .target
  }

  private func updatePreparedReleases(for current: OrbitDrag, docking: OrbitDockingTarget?) {
    var prepared =
      reduceMotion
      ? nil
      : model.orbitPreparedRelease(
        for: current.format, from: current.origin, docking: docking)
    if prepared != nil,
      let next = model.orbitPreviewSelection(
        for: current.format, from: current.origin, docking: docking)
    {
      preparedRingPlan = OrbitReturnPlan.make(
        before: current.selection, after: next, order: ringOrder, size: current.orbitSize)
    }
    if current.settling, current.settlingSelection != current.selection, prepared != nil {
      prepared?.progress = OrbitReleasePresentation.settlementLimit
    }
    for format in NativeFormatOrbit.formats {
      guard !departures.contains(where: { $0.format == format }) else { continue }
      let old = releasePresentations[format]
      let next: OrbitReleasePresentation?
      if prepared?.item.format == format {
        next = prepared
      } else if let old {
        next = OrbitReleasePresentation(item: old.item, progress: 0)
      } else {
        next = nil
      }
      guard next != old else { continue }
      let increasing = (next?.progress ?? 0) > (old?.progress ?? 0)
      let token = UUID()
      clearanceTokens[format] = token
      if (next?.progress ?? 0) > 0 { clearanceFormats.insert(format) }
      let duration =
        current.settling && increasing
        ? OrbitDragGeometry.chamberDuration
        : (increasing ? OrbitDragGeometry.approachDuration : OrbitDragGeometry.retractDuration)
      withAnimation(
        reduceMotion ? nil : .easeInOut(duration: duration), completionCriteria: .removed
      ) {
        releasePresentations[format] = next
      } completion: {
        guard clearanceTokens[format] == token, (releasePresentations[format]?.progress ?? 0) == 0
        else { return }
        clearanceFormats.remove(format)
        if clearanceFormats.isEmpty { preparedRingPlan = nil }
      }
    }
  }

  private func departureLayer(size: CGFloat, diameter: CGFloat, phase: Double) -> some View {
    ZStack {
      ForEach(NativeFormatOrbit.formats, id: \.self) { format in
        let presentation = releasePresentations[format]
        OrbitReturningModule(
          progress: presentation?.progress ?? 0, format: format, diameter: diameter,
          roles: model.orbitRoles(for: format),
          path: OrbitDeparturePath(
            slot: presentation?.item.slot ?? .source,
            destination: homePosition(format, among: ringFormats, size: size, phase: phase),
            layout: HourglassLayout(orbitSize: size)))
      }
    }
    .allowsHitTesting(false).accessibilityHidden(true)
  }

  private func animateDepartures() {
    let id = departureID
    for item in departures {
      guard let start = releasePresentations[item.format] else { continue }
      withAnimation(
        reduceMotion ? nil : .linear(duration: start.remainingDuration),
        completionCriteria: .removed
      ) {
        releasePresentations[item.format]?.progress = 1
      } completion: {
        guard departureID == id else { return }
        // The same presentation reached the ring; reveal its stationary counterpart.
        releasePresentations[item.format] = nil
        clearanceFormats.remove(item.format)
        departures.removeAll { $0.format == item.format }
      }
    }
  }

  private func cancelDepartures() {
    departureID = UUID()
    departures = []
    releasePresentations = [:]
    clearanceFormats = []
    clearanceTokens = [:]
    preparedRingPlan = nil
  }

  private func select(_ format: String) {
    guard acceptsClick else { return }
    guard let destination = model.orbitDestinations(for: format, activeSlot: activeSlot).first
    else { return }
    assign(format, to: destination)
  }

  private func assign(_ format: String, to slot: FormatRouteSlot) {
    guard acceptsClick else { return }
    guard model.orbitDestinations(for: format, activeSlot: slot).contains(slot) else { return }
    withAnimation(motion) {
      if !model.dropFormat(format, to: slot) {
        selectionHint = "此组合暂不支持；可先移除中央模块，再选择格式"
      }
    }
  }

  private func remove(_ format: String, from slot: FormatRouteSlot) {
    guard acceptsClick else { return }
    withAnimation(motion) { _ = model.dropFormat(format, from: slot, to: nil) }
  }

}

struct OrbitFormatButton: View {
  @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let format: String
  let diameter: CGFloat
  let selected: Bool
  let roles: OrbitFormatRoles
  let enabled: Bool
  var chamberAppearance = 0.0
  var labelOpacity = 1.0
  var concealed = false
  var previewRoles: OrbitFormatRoles? = nil
  var previewAmount = 0.0
  var supportOverride: [Double]? = nil
  var moduleSize: CGSize? = nil
  var labelWidth: CGFloat? = nil
  var morphSlot: FormatRouteSlot = .source
  var morphAmount = 0.0
  let action: () -> Void

  var body: some View {
    let width = moduleSize?.width ?? diameter
    let height = moduleSize?.height ?? diameter
    let shape = OrbitModuleShape(slot: morphSlot, amount: morphAmount)
    let displayedRoles = previewAmount > 0 ? (previewRoles ?? roles) : roles
    let sourceSupport =
      supportOverride?.first ?? support(roles.source, preview: previewRoles?.source)
    let targetSupport =
      supportOverride?.last ?? support(roles.target, preview: previewRoles?.target)
    Button(action: action) {
      ZStack {
        Color.clear.frame(width: width, height: height)
        if !concealed {
          VStack(spacing: 7) {
            Image(systemName: NativeFormatOrbit.symbol(format)).font(.system(size: diameter * 0.24))
            Text(NativeFormatOrbit.title(format))
              .font(.system(size: diameter < 75 ? 11 : 13, weight: .medium))
              .lineLimit(1).minimumScaleFactor(0.8)
          }
          .frame(width: labelWidth)
          .foregroundStyle(TransallTheme.ink)
          .opacity(labelOpacity)
          .offset(y: height * morphAmount * (morphSlot == .source ? -0.15 : 0.15))
          .frame(width: width, height: height)
          .overlay(alignment: .topTrailing) {
            if differentiateWithoutColor && !displayedRoles.source {
              Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).padding(7)
            }
          }
          .overlay(alignment: .bottomTrailing) {
            if differentiateWithoutColor && !displayedRoles.target {
              Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).padding(7)
            }
          }
          .modifier(
            OrbitModuleSurface(
              selected: selected, sourceSupport: sourceSupport, targetSupport: targetSupport,
              shape: shape, chamberAppearance: chamberAppearance
            )
          )
          .animation(
            reduceMotion
              ? nil
              : .easeInOut(
                duration: previewAmount > 0
                  ? OrbitDragGeometry.approachDuration : OrbitDragGeometry.retractDuration),
            value: [sourceSupport, targetSupport])
        }
      }
      .contentShape(shape)
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .accessibilityLabel(NativeFormatOrbit.title(format))
    .accessibilityValue(displayedRoles.description)
    .accessibilityHint("上半部代表源格式，下半部代表输出格式；拖入对应腔室，或点击选择")
    .help(displayedRoles.description)
  }

  private func support(_ current: Bool, preview: Bool?) -> Double {
    let start = current ? 1.0 : 0.0
    let end = (preview ?? current) ? 1.0 : 0.0
    return start + (end - start) * max(0, min(1, previewAmount))
  }
}

private struct OrbitModuleSurface: ViewModifier, Animatable {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let selected: Bool
  nonisolated var sourceSupport: Double
  nonisolated var targetSupport: Double
  let shape: OrbitModuleShape
  let chamberAppearance: Double

  nonisolated var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(sourceSupport, targetSupport) }
    set {
      sourceSupport = newValue.first
      targetSupport = newValue.second
    }
  }

  private func roleGradient() -> LinearGradient {
    // Supported halves reveal the same native surface as the empty chamber.
    let unavailable = Color(nsColor: .textBackgroundColor)
    let source = unavailable.opacity(1 - sourceSupport)
    let target = unavailable.opacity(1 - targetSupport)
    return LinearGradient(
      stops: [
        .init(color: source, location: 0), .init(color: source, location: 0.28),
        .init(color: target, location: 0.72), .init(color: target, location: 1),
      ], startPoint: .top, endPoint: .bottom)
  }

  private func fill(glass: Bool) -> some View {
    ZStack {
      if !glass { TransallTheme.orbitVacancy }
      roleGradient().opacity(1 - chamberAppearance)
    }.clipShape(shape)
  }

  func body(content: Content) -> some View {
    if #available(macOS 26.0, *), !reduceTransparency, contrast != .increased {
      content.background { fill(glass: true) }
        .glassEffect(.regular.interactive(), in: shape)
    } else {
      content.background { fill(glass: false) }
        .overlay {
          shape.stroke(selected ? TransallTheme.accent : TransallTheme.inkSoft, lineWidth: 1)
        }
    }
  }
}

struct InputFileListView: View {
  @EnvironmentObject private var model: AppModel

  var body: some View {
    List(
      selection: Binding<URL?>(
        get: { model.showInputPreview ? model.selectedDocumentID : nil },
        set: { model.selectedDocumentID = $0 }
      )
    ) {
      Section {
        ForEach(model.documents) { document in
          HStack(spacing: 8) {
            Image(
              systemName: document.url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc"
            )
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(document.name).lineLimit(1).truncationMode(.middle)
              Text(document.formattedSize).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("移除文件", systemImage: "xmark") { model.removeDocument(document) }
              .labelStyle(.iconOnly).buttonStyle(.borderless)
              .disabled(!model.canSelectDocuments && (model.isImporting || !model.canEditTaskDraft))
              .accessibilityLabel("移除\(document.name)")
          }
          .help(document.name).tag(document.id)
        }
        if model.documents.isEmpty {
          Text("尚未添加文件").font(.callout).foregroundStyle(.secondary)
        }
      } header: {
        HStack {
          Text("文件 · \(model.documents.count)")
          Spacer()
          Button("添加文件", systemImage: "plus") {
            NotificationCenter.default.post(name: .transallChooseDocuments, object: nil)
          }
          .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(!model.canSelectDocuments)
        }
      }
    }
    .listStyle(.sidebar)
    .accessibilityLabel("当前任务的文件")
  }
}
