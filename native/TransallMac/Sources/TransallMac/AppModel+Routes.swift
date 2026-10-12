import SwiftUI

extension AppModel {
  func canChooseFormat(_ format: String) -> Bool {
    guard canChangeRoute else { return false }
    if selection.source == nil || selection.target != nil {
      return NativeCapabilities.routes.contains { $0.source == format && $0.enabled }
    }
    return NativeCapabilities.routes.contains {
      $0.source == selection.source && $0.target == format && $0.enabled
    }
  }

  func chooseFormat(_ format: String, animated: Bool = true) {
    if let routeChangeLock {
      errorMessage = routeChangeLock.errorMessage(reset: false)
      return
    }
    guard canChooseFormat(format) else { return }
    var next = selection
    next.choose(format)
    resetFormatSelection()
    selection = next
  }

  // A slot drag is validated as one operation, so an invalid swap cannot erase a draft.
  func formatSelection(
    dropping format: String, from origin: FormatRouteSlot? = nil, to destination: FormatRouteSlot?
  ) -> RouteSelection? {
    guard canChangeRoute else { return nil }
    var next = selection
    if let origin {
      guard next[origin] == format else { return nil }
      if origin == destination { return next }
      next[origin] = destination.flatMap { next[$0] }
    } else if destination == nil {
      return nil
    }
    if let destination { next[destination] = format }
    guard supportsFormatSelection(next) else { return nil }
    return next
  }

  private func supportsFormatSelection(_ selection: RouteSelection) -> Bool {
    NativeCapabilities.routes.contains {
      $0.enabled && (selection.source == nil || $0.source == selection.source)
        && (selection.target == nil || $0.target == selection.target)
    }
  }

  var formatReversalDisabledReason: String? {
    if let routeChangeLock { return routeChangeLock.helpText }
    if selection.source == nil && selection.target == nil { return "请先选择格式" }
    if selection.source == selection.target { return "源格式与目标格式相同" }
    guard supportsFormatSelection(selection.reversed) else {
      if let source = selection.target, let target = selection.source {
        return "暂不支持 \(NativeFormatOrbit.title(source)) → \(NativeFormatOrbit.title(target))"
      }
      let slot: FormatRouteSlot = selection.source == nil ? .source : .target
      let format = selection.source ?? selection.target ?? ""
      return "\(NativeFormatOrbit.title(format)) 不能用作\(slot.title)"
    }
    return nil
  }

  @discardableResult
  func reverseFormats(expectedSelection: RouteSelection) -> Bool {
    guard selection == expectedSelection, formatReversalDisabledReason == nil else { return false }
    return applyFormatSelection(selection.reversed)
  }

  @discardableResult
  func dropFormat(
    _ format: String, from origin: FormatRouteSlot? = nil, to destination: FormatRouteSlot?
  ) -> Bool {
    guard let next = formatSelection(dropping: format, from: origin, to: destination) else {
      return false
    }
    return applyFormatSelection(next)
  }

  private func applyFormatSelection(_ next: RouteSelection) -> Bool {
    guard next != selection else { return true }
    clearRouteDraft()
    options = JobOptions()
    if let provider = providers.first(where: \.configured) { options.provider = provider.name }
    showAdvanced = false
    selection = next
    return true
  }

  func orbitDockingFeedback(
    for format: String, from origin: FormatRouteSlot?, at point: CGPoint,
    layout: HourglassLayout
  ) -> OrbitDockingTarget? {
    guard canChangeRoute else { return nil }
    // An occupied chamber uses the same compatibility and morph feedback as an empty one.
    // Prefer the actual hit chamber so the neighboring role cannot steal a replacement.
    let candidates = layout.slot(at: point).map { [$0] } ?? FormatRouteSlot.allCases
    return candidates.compactMap { slot -> OrbitDockingTarget? in
      let frame = layout.slotFrame(slot)
      let strength = NativeFormatOrbit.dockingStrength(at: point, to: frame, slot: slot)
      guard strength > 0 else { return nil }
      return OrbitDockingTarget(
        slot: slot, frame: frame, strength: strength,
        compatibility: formatSelection(dropping: format, from: origin, to: slot) == nil
          ? .incompatible : .compatible)
    }.max { $0.strength < $1.strength }
  }

  func orbitPreparedRelease(
    for format: String, from origin: FormatRouteSlot?, docking: OrbitDockingTarget?
  ) -> OrbitReleasePresentation? {
    guard let docking, docking.compatibility == .compatible,
      let old = selection[docking.slot], old != format,
      let next = formatSelection(dropping: format, from: origin, to: docking.slot),
      next.source != old, next.target != old
    else { return nil }
    return .preparation(
      item: OrbitReleasedFormat(format: old, slot: docking.slot),
      strength: docking.strength)
  }

  func orbitDropSelection(
    for format: String, from origin: FormatRouteSlot?, at point: CGPoint,
    layout: HourglassLayout
  ) -> RouteSelection? {
    let slot = layout.slot(at: point)
    // The waist belongs to neither chamber; dropping there must not remove an occupied format.
    guard slot != nil || !layout.frame.contains(point) else { return nil }
    return formatSelection(dropping: format, from: origin, to: slot)
  }

  func orbitPreviewSelection(
    for format: String, from origin: FormatRouteSlot?, docking: OrbitDockingTarget?
  ) -> RouteSelection? {
    guard let docking, docking.compatibility == .compatible, docking.strength > 0 else {
      return nil
    }
    return formatSelection(dropping: format, from: origin, to: docking.slot)
  }

  func orbitRoles(for format: String, selection preview: RouteSelection? = nil) -> OrbitFormatRoles
  {
    let selection = preview ?? self.selection
    var asSource = selection
    asSource.source = format
    var asTarget = selection
    asTarget.target = format
    return OrbitFormatRoles(
      source: supportsFormatSelection(asSource), target: supportsFormatSelection(asTarget))
  }

  func orbitDestinations(for format: String, activeSlot: FormatRouteSlot) -> [FormatRouteSlot] {
    NativeFormatOrbit.candidateSlots(for: selection, activeSlot: activeSlot).filter {
      formatSelection(dropping: format, to: $0) != nil
    }
  }

  func resetFormatSelection(keepingSource: Bool = false) {
    guard canChangeRoute else { return }
    let source = keepingSource ? selection.source : nil
    resetRoute(animated: false)
    selection.source = source
    options = JobOptions()
    if let provider = providers.first(where: \.configured) { options.provider = provider.name }
    showAdvanced = false
  }

  func resetRoute(animated: Bool = true) {
    if let routeChangeLock {
      errorMessage = routeChangeLock.errorMessage(reset: true)
      return
    }
    let changes = { [self] in
      clearRouteDraft()
      selection.clear()
    }
    if animated {
      withAnimation(.easeOut(duration: 0.3), changes)
    } else {
      changes()
    }
  }

  private func clearRouteDraft() {
    pollingTask?.cancel()
    preferences.removeObject(forKey: lastJobKey)
    inspectionPage = 1
    showInputPreview = false
    documents = []
    currentJob = nil
    resultOriginalDocuments = nil
    previewPages = []
    previewError = nil
    isLoadingPreview = false
    preflightWarnings = []
    errorMessage = nil
  }
}
