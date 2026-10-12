import Vision

extension PDFLayoutTranslation {
  static func linkPageContinuations(
    _ regions: [PDFTranslationRegion], pageBounds: [CGRect]
  ) -> [PDFTranslationRegion] {
    var result = regions.map { region in
      var value = region
      value.continuationGroup = nil
      value.continuationVersion = nil
      return value
    }
    let pages = Dictionary(grouping: regions.indices, by: { regions[$0].pageIndex })
    func normalized(_ text: String) -> String {
      text.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let repeated = Dictionary(
      grouping: regions.filter {
        guard pageBounds.indices.contains($0.pageIndex), $0.sourceText.count < 180 else {
          return false
        }
        let box = pageBounds[$0.pageIndex]
        return $0.bounds.midY < box.minY + box.height * 0.12
          || $0.bounds.midY > box.maxY - box.height * 0.12
      },
      by: {
        normalized($0.sourceText)
      }
    ).filter { Set($0.value.map(\.pageIndex)).count > 1 }
    func isCaption(_ text: String) -> Bool {
      text.range(
        of: #"(?i)^\s*(?:fig(?:ure)?\.?\s*\d|table\s*\d|图\s*\d|表\s*\d)"#,
        options: .regularExpression) != nil
    }
    func bodyOrder(_ page: Int) -> [Int] {
      let box = pageBounds[page]
      let available = pages[page, default: []].filter { regions[$0].preserveOriginal != true }
      // OCR is body text only on pages without a usable native text layer. This
      // avoids treating labels inside a figure as the next paragraph.
      let native = available.filter { regions[$0].kind == .nativeText }
      let candidates = native.isEmpty ? available.filter { regions[$0].kind == .imageOCR } : native
      let fonts = candidates.filter { regions[$0].sourceText.count >= 80 }
        .map { regions[$0].preferredFontSize }.sorted()
      let bodyFont = fonts.isEmpty ? CGFloat(0) : fonts[fonts.count / 2]
      // Table titles and notes delimit an obstacle in the reading stream, not prose.
      let tableZones = candidates.compactMap { index -> CGRect? in
        let title = regions[index]
        guard title.sourceText.range(of: #"(?i)^table\s*\d"#, options: .regularExpression) != nil,
          let note = candidates.map({ regions[$0] }).filter({
            $0.bounds.maxY < title.bounds.minY && $0.bounds.minX >= title.bounds.minX - 12
              && $0.sourceText.range(of: #"(?i)^note(?:s)?[:.]"#, options: .regularExpression)
                != nil
          }).max(by: { $0.bounds.maxY < $1.bounds.maxY })
        else { return nil }
        return title.bounds.union(note.bounds)
      }
      let body = candidates.filter { index in
        let r = regions[index]
        let isHeading =
          r.sourceText.range(
            of: #"^\d+(?:\.\d+)*[.]?\s+\p{L}"#,
            options: .regularExpression) != nil || r.bold == true
        return r.bounds.midY > box.minY + box.height * 0.05
          && r.bounds.midY < box.maxY - box.height * 0.05
          && !((r.bounds.midY < box.minY + box.height * 0.12
            || r.bounds.midY > box.maxY - box.height * 0.12)
            && r.sourceText.count < 180 && repeated[normalized(r.sourceText)] != nil)
          && (isHeading || r.preferredFontSize >= bodyFont * 0.8)
          && r.sourceText.range(of: #"^\s*\d+\s*$"#, options: .regularExpression) == nil
          && !isCaption(r.sourceText)
          && !tableZones.contains(where: {
            $0.contains(CGPoint(x: r.bounds.midX, y: r.bounds.midY))
          })
          && (isHeading || (r.sourceText.count >= 4 && r.bounds.width >= r.preferredFontSize * 2))
      }
      return readingOrder(body, regions: regions)
    }
    func prose(_ r: PDFTranslationRegion) -> Bool {
      let text = r.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
      return r.bold != true && r.centered != true && text.count >= 4
        && text.contains(where: \.isLetter)
        && text.range(of: #"^\d+(?:\.\d+)*[.]?\s+\p{L}"#, options: .regularExpression) == nil
        && text.range(
          of:
            #"(?i)^(?:fig(?:ure)?\.?|table|references|bibliography|图|表|参考文献|\[\d+\]|\d+[.)])(?:\s|$)"#,
          options: .regularExpression) == nil
    }
    guard !pageBounds.isEmpty else { return result }
    let orders = pageBounds.indices.map { bodyOrder($0) }
    var boundaries: [(Int, Int)] = []
    for page in pageBounds.indices {
      let order = orders[page]
      for (end, start) in zip(order, order.dropFirst()) {
        let a = regions[end].bounds
        let b = regions[start].bounds
        let separateColumns = a.maxX <= b.minX
        let sameColumn =
          abs(a.minX - b.minX) <= regions[end].preferredFontSize * 1.5
          && b.maxY <= a.minY + 2
          && a.minY - b.maxY <= regions[end].preferredFontSize * 1.8
        if separateColumns || sameColumn { boundaries.append((end, start)) }
      }
      if page + 1 < pageBounds.count, let end = order.last, let start = orders[page + 1].first {
        boundaries.append((end, start))
      }
    }
    for (end, start) in boundaries {
      let a = regions[end]
      let b = regions[start]
      let tail = a.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
      let head = b.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
      let strippedTail = tail.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]}"))
      let lowerStart = head.first?.isLowercase == true
      let technicalStart =
        head.range(of: #"^[A-Z][A-Za-z]*[0-9]+\b"#, options: .regularExpression) != nil
      let connectiveTail = [
        "and", "or", "the", "of", "to", "with", "in", "from", "by", "for", "as", "using",
      ]
      .contains(tail.split(whereSeparator: \.isWhitespace).last.map { $0.lowercased() } ?? "")
      let cjkStart =
        head.unicodeScalars.first.map {
          (0x3040...0x30FF).contains(Int($0.value)) || (0x3400...0x9FFF).contains(Int($0.value))
            || (0xAC00...0xD7AF).contains(Int($0.value))
        } ?? false
      let abbreviation =
        strippedTail.range(
          of: #"(?i)(?:\b(?:e\.g|i\.e|et al|vs|cf|dr|prof|fig|eq)|\b[A-Z])\.$"#,
          options: .regularExpression) != nil
      let openDelimiter = [("(", ")"), ("[", "]"), ("（", "）")].contains { opening, closing in
        tail.components(separatedBy: opening).count > tail.components(separatedBy: closing).count
      }
      guard prose(a), prose(b), a.kind == b.kind,
        tail.count + head.count >= 35,
        abs(a.preferredFontSize - b.preferredFontSize) <= max(0.75, a.preferredFontSize * 0.12),
        !(strippedTail.last.map { ".!?。！？".contains($0) } ?? true) || abbreviation,
        lowerStart || cjkStart || technicalStart || connectiveTail || openDelimiter,
        // Short fragments require a clear lexical continuation, not just matching geometry.
        min(tail.count, head.count) >= 12 || lowerStart || cjkStart,
        !head.hasPrefix("http"), !head.hasPrefix("doi:")
      else { continue }
      let group = (result[end].continuationGroup ?? [a.id]) + [b.id]
      let members = result.indices.filter { group.contains(result[$0].id) }
      guard members.reduce(0, { $0 + result[$1].sourceText.count }) <= 12_000 else { continue }
      for index in members {
        result[index].continuationGroup = group
        result[index].continuationVersion = 3
      }
    }
    return result
  }

  /// Recursive whitespace cuts infer columns from the actual text geometry.
  /// A spanning heading splits the page into horizontal bands before columns
  /// are inferred within each band. No fixed page midpoint or column count.
  static func readingOrder(_ indices: [Int], regions: [PDFTranslationRegion]) -> [Int] {
    guard indices.count > 1 else { return indices }
    func cut(vertical: Bool) -> ([Int], [Int])? {
      let sorted = indices.sorted {
        let a = regions[$0].bounds
        let b = regions[$1].bounds
        return vertical ? a.minX < b.minX : a.minY < b.minY
      }
      var edge = vertical ? regions[sorted[0]].bounds.maxX : regions[sorted[0]].bounds.maxY
      var best: (Int, CGFloat)?
      for offset in 1..<sorted.count {
        let box = regions[sorted[offset]].bounds
        let gap = (vertical ? box.minX : box.minY) - edge
        let threshold: CGFloat = vertical ? 4 : 2
        if gap > threshold, best == nil || gap > best!.1 { best = (offset, gap) }
        edge = max(edge, vertical ? box.maxX : box.maxY)
      }
      guard let best else { return nil }
      let low = Array(sorted.prefix(best.0))
      let high = Array(sorted.dropFirst(best.0))
      return vertical ? (low, high) : (high, low)
    }
    if let (first, second) = cut(vertical: true) ?? cut(vertical: false) {
      return readingOrder(first, regions: regions) + readingOrder(second, regions: regions)
    }
    return indices.sorted {
      let a = regions[$0].bounds
      let b = regions[$1].bounds
      if abs(a.maxY - b.maxY) > 2 { return a.maxY > b.maxY }
      if a.minX != b.minX { return a.minX < b.minX }
      return regions[$0].id < regions[$1].id
    }
  }
}
