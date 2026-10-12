import Foundation
import Testing

@testable import TransallMac

@Suite("Page translation scheduling")
struct PageTranslationTests {
  @Test(arguments: [false, true])
  func pagesRunTogetherWithoutOverlappingRegionsFromOnePage(resuming: Bool) async throws {
    let probe = PageTranslationProbe()
    let regions = (0..<6).flatMap { page in
      (0..<3).map { region in
        PDFTranslationRegion(
          id: "p\(page)-r\(region)", pageIndex: page, kind: .nativeText,
          bounds: CGRect(x: 0, y: region * 20, width: 100, height: 14),
          sourceText: "p\(page)-r\(region)", preferredFontSize: 10)
      }
    }
    let existing =
      resuming
      ? Dictionary(uniqueKeysWithValues: regions.prefix(4).map { ($0.id, "saved-" + $0.id) })
      : [:]
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: 4,
      requestSender: { try await probe.send($0, regions: true) })
    let result = try await ProcessingProgress.$reporter.withValue(
      { await probe.record($0) },
      operation: {
        try await service.translateRegions(
          regions, source: "en", target: "zh", glossary: "", existingTranslations: existing,
          checkpoint: { await probe.save($0) })
      })
    #expect(result.count == regions.count)
    for region in regions {
      #expect(result[region.id] == existing[region.id] ?? "translated-" + region.id)
    }
    let state = await probe.snapshot()
    #expect(state.peak == 4)
    #expect(!state.overlappedPage)
    #expect(Set(state.started.prefix(4)) == Set(resuming ? [1, 2, 3, 4] : [0, 1, 2, 3]))
    #expect(state.checkpoints.count == regions.count - existing.count)
    for (index, checkpoint) in state.checkpoints.enumerated() {
      #expect(checkpoint.count == existing.count + index + 1)
      for (id, text) in existing { #expect(checkpoint[id] == text) }
    }
    let lines = state.progress.filter { $0.id != "main" && $0.id != "translation-total" }
    #expect(lines.contains { $0.title.contains("第 2 页") && $0.fraction == 1.0 / 3 })
    #expect(lines.filter { $0.title.hasSuffix("页已完成") }.count == (resuming ? 5 : 6))
    #expect(state.progress.last { $0.id == "translation-total" }?.fraction == 1)
  }

  @Test
  func checkpointFailureStopsTheQueueBeforeStartingMorePages() async throws {
    let probe = PageTranslationProbe()
    let regions = (0..<8).map { page in
      PDFTranslationRegion(
        id: "p\(page)-r0", pageIndex: page, kind: .nativeText,
        bounds: CGRect(x: 0, y: 0, width: 100, height: 14),
        sourceText: "p\(page)-r0", preferredFontSize: 10)
    }
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: 4,
      requestSender: { try await probe.send($0, regions: true) })
    await #expect(throws: CancellationError.self) {
      _ = try await service.translateRegions(
        regions, source: "en", target: "zh", glossary: "",
        checkpoint: {
          await probe.save($0)
          throw CancellationError()
        })
    }
    let state = await probe.snapshot()
    #expect(Set(state.started) == Set(0..<4))
    #expect(state.checkpoints.count == 1)
    #expect(state.checkpoints.first?.count == 1)
  }

  @Test
  func plainTranslationKeepsPageOrderDespiteCompletionOrder() async throws {
    let probe = PageTranslationProbe()
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: 4,
      requestSender: { try await probe.send($0, regions: false) })
    let pages = (0..<6).map { "p\($0)-r0" } + [""]
    let result = try await service.translatePages(pages, source: "en", target: "zh", glossary: "")
    #expect(Array(result.prefix(6)) == pages.prefix(6).map { "translated-" + $0 })
    #expect(result.last == "第 7 页没有可提取的文字。")
    let state = await probe.snapshot()
    #expect(state.peak == 4)
    #expect(state.started.count == 6)
    #expect(state.finished.first != 0)
  }
}

private actor PageTranslationProbe {
  struct Snapshot: Sendable {
    var started: [Int] = []
    var finished: [Int] = []
    var peak = 0
    var overlappedPage = false
    var progress: [TaskProgressLine] = []
    var checkpoints: [[String: String]] = []
  }
  private var state = Snapshot()
  private var active: Set<Int> = []
  func record(_ line: TaskProgressLine) { state.progress.append(line) }
  func save(_ value: [String: String]) { state.checkpoints.append(value) }
  func snapshot() -> Snapshot { state }

  func send(_ request: URLRequest, regions: Bool) async throws -> (Data, URLResponse) {
    let data = try #require(request.httpBody)
    let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let messages = try #require(payload["messages"] as? [[String: String]])
    let content = try #require(messages.last?["content"])
    let text: String
    if regions {
      let input = try #require(
        JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
      let items = try #require(input["items"] as? [[String: String]])
      #expect(items.count == 1)
      text = try #require(items.first?["id"])
    } else {
      text = String(content.split(separator: "\n").last ?? "")
    }
    let page = try #require(Int(text.dropFirst().prefix(while: { $0.isNumber })))
    if active.contains(page) { state.overlappedPage = true }
    active.insert(page)
    state.started.append(page)
    state.peak = max(state.peak, active.count)
    defer { active.remove(page) }
    try await Task.sleep(for: .milliseconds(page == 0 ? 160 : 40))
    state.finished.append(page)
    let responseContent: String
    if regions {
      let json = try JSONSerialization.data(withJSONObject: [
        "items": [["id": text, "text": "translated-" + text]]
      ])
      responseContent = String(decoding: json, as: UTF8.self)
    } else {
      responseContent = "translated-" + text
    }
    let response = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": responseContent]]]
    ])
    return (
      response,
      try #require(
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
    )
  }
}
