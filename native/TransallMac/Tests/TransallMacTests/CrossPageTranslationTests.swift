import Foundation
import Testing

@testable import TransallMac

@Suite("Cross-page translation continuity")
struct CrossPageTranslationTests {
  private let box = CGRect(x: 0, y: 0, width: 600, height: 800)
  private func region(_ id: String, page: Int, x: Double = 50, y: Double, text: String)
    -> PDFTranslationRegion
  {
    PDFTranslationRegion(
      id: id, pageIndex: page, kind: .nativeText,
      bounds: CGRect(x: x, y: y, width: 240, height: 60), sourceText: text,
      preferredFontSize: 11)
  }
  private var pair: [PDFTranslationRegion] {
    [
      region(
        "a", page: 0, y: 80, text: "The treatment improved the long-term stability of the inter-"),
      region(
        "b", page: 1, y: 670, text: "cellular network and reduced inflammation in all participants."
      ),
    ]
  }
  private func linked(_ values: [PDFTranslationRegion]) -> [PDFTranslationRegion] {
    PDFLayoutTranslation.linkPageContinuations(values, pageBounds: [box, box, box])
  }

  @Test func linksHyphenatedSentenceAndUsesColumnReadingOrder() {
    let left = region(
      "left", page: 0, y: 70, text: "This is an unrelated complete paragraph in the left column.")
    var right = pair[0]
    right = PDFTranslationRegion(
      id: right.id, pageIndex: 0, kind: .nativeText,
      bounds: CGRect(x: 320, y: 90, width: 230, height: 60),
      sourceText: right.sourceText, preferredFontSize: 11)
    let footer = region(
      "footer", page: 0, y: 5, text: "Journal of unrelated scientific investigations 2026")
    let result = linked([left, footer, pair[1], right])
    #expect(result.first { $0.id == "a" }?.continuationGroup == ["a", "b"])
    #expect(result.first { $0.id == "b" }?.continuationGroup == ["a", "b"])
    #expect(result.first { $0.id == "left" }?.continuationGroup == nil)
    #expect(result.first { $0.id == "footer" }?.continuationGroup == nil)
  }

  @Test(arguments: ["complete.", "complete.”", "complete!"])
  func terminalPunctuationDoesNotLink(ending: String) {
    let a = region(
      "a", page: 0, y: 80, text: "The treatment improved the cellular network and was " + ending)
    #expect(linked([a, pair[1]]).allSatisfy { $0.continuationGroup == nil })
  }

  @Test func geneNameAtNextPageIsRecognizedAsContinuation() {
    let a = region(
      "a", page: 0, y: 80, text: "The analysis identified tear-EV-associated proteins including")
    let b = region(
      "b", page: 1, y: 670, text: "LRG1 and HSPG2, which were elevated in these samples.")
    #expect(linked([a, b]).allSatisfy { $0.continuationGroup == ["a", "b"] })
  }

  @Test func headingsCaptionsOCRAndNewSentencesDoNotLink() {
    var heading = pair[1]
    heading.bold = true
    var ocr = pair[1]
    ocr = PDFTranslationRegion(
      id: ocr.id, pageIndex: 1, kind: .imageOCR, bounds: ocr.bounds,
      sourceText: ocr.sourceText, preferredFontSize: 11)
    let caption = region(
      "b", page: 1, y: 670, text: "figure 2. The network of interactions between cells.")
    let newParagraph = region(
      "b", page: 1, y: 670, text: "The next experiment investigated another hypothesis.")
    for next in [heading, ocr, caption, newParagraph] {
      #expect(linked([pair[0], next]).allSatisfy { $0.continuationGroup == nil })
    }
  }

  @Test func figuresDoNotHidePageAndColumnContinuations() async throws {
    let a = region(
      "a", page: 0, x: 320, y: 420,
      text: "We screened metabolites using VIP: value of variable importance in the")
    let b = region(
      "b", page: 1, y: 240,
      text: "projection; FC: fold change, followed by correlation analysis.")
    let c = region(
      "c", page: 1, y: 60,
      text: "These enriched pathways include glycine metabolism; arginine metabolism;")
    let d = region(
      "d", page: 1, x: 320, y: 350,
      text: "cysteine metabolism; and glutathione metabolism, which are affected by infection.")
    let figureBefore = region(
      "figure0", page: 0, y: 60,
      text: "Fig. 1. Schematic of the tear nanoparticle isolation and analysis.")
    let figureAfter = region(
      "figure1", page: 1, y: 430,
      text: "Fig. 2. Characterization and global metabolic profile of tear particles.")
    let result = linked([a, figureBefore, b, c, d, figureAfter])
    #expect(result.first { $0.id == "a" }?.continuationGroup == ["a", "b"])
    #expect(result.first { $0.id == "c" }?.continuationGroup == ["c", "d"])
    #expect(linked(result) == result)
    let probe = ContinuityProbe()
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: 4,
      requestSender: { try await probe.send($0) })
    _ = try await service.translateRegions(
      result, source: "en", target: "zh", glossary: "",
      existingTranslations: ["figure0": "图1", "figure1": "图2"])
    #expect(await probe.snapshot().requests == [["a", "b"], ["c", "d"]])
  }

  @Test func chineseBoundaryKeepsTerminologyWholeWithoutChangingCombinedText() async throws {
    let input = [
      "a": "随后筛选符合标准的代谢物（VIP：变量投影重要性",
      "b": "值；FC：倍数变化），比较感染组与对照组。随后开展相关性分析。",
    ]
    let result = TranslationService.alignContinuationBoundaries(
      input, regions: linked(pair), target: "zh")
    #expect(result["a"]!.hasSuffix("变量投影重要性值；"))
    #expect(result["b"]!.hasPrefix("FC：倍数变化"))
    #expect(result["a"]! + result["b"]! == input["a"]! + input["b"]!)
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key",
      requestSender: { _ in
        throw CancellationError()
      })
    let resumed = try await service.translateRegions(
      linked(pair), source: "en", target: "zh", glossary: "",
      existingTranslations: input)
    #expect(resumed == result)
    #expect(
      TranslationService.alignContinuationBoundaries(input, regions: linked(pair), target: "en")
        == input)
  }

  private func boxRegion(
    _ id: String, page: Int = 0, x: Double, y: Double, width: Double = 155,
    text: String, kind: PDFTranslationRegion.Kind = .nativeText, font: Double = 11
  ) -> PDFTranslationRegion {
    PDFTranslationRegion(
      id: id, pageIndex: page, kind: kind,
      bounds: CGRect(x: x, y: y, width: width, height: 40), sourceText: text,
      preferredFontSize: font)
  }

  @Test func threeUnequalColumnsFollowActualGutters() {
    let a = boxRegion(
      "a", x: 35, y: 150, width: 120,
      text: "The observed changes were associated with the")
    let b = boxRegion(
      "b", x: 180, y: 600, width: 180,
      text: "inflammatory response, including changes in the")
    let c = boxRegion(
      "c", x: 385, y: 540, width: 170,
      text: "cellular network and the surrounding tissue.")
    let result = linked([c, a, b])
    #expect(result.allSatisfy { $0.continuationGroup == ["a", "b", "c"] })
  }

  @Test func spanningHeadingSeparatesColumnBandsAndBlocksJoining() {
    let a = boxRegion("a", x: 35, y: 650, text: "The first section describes changes in the")
    let b = boxRegion("b", x: 320, y: 650, text: "cellular network, with ongoing changes in the")
    var title = boxRegion("title", x: 35, y: 400, width: 520, text: "Discussion")
    title.bold = true
    let c = boxRegion(
      "c", x: 35, y: 200, text: "the next section describes the clinical implications.")
    let d = boxRegion(
      "d", x: 320, y: 250, text: "The final paragraph ends this independent discussion.")
    let values = [d, title, c, b, a]
    #expect(
      PDFLayoutTranslation.readingOrder(Array(values.indices), regions: values)
        .map { values[$0].id } == ["a", "b", "title", "c", "d"])
    let result = linked(values)
    #expect(result.first { $0.id == "b" }?.continuationGroup == ["a", "b"])
    #expect(result.first { $0.id == "c" }?.continuationGroup == nil)
  }

  @Test func shortFragmentAndNearbySameColumnBlocksAreJoined() {
    let a = boxRegion(
      "a", x: 40, y: 500, width: 240,
      text: "The treatment improved stability of the inter-")
    let b = boxRegion("b", x: 40, y: 451, width: 65, text: "cellular")
    let c = boxRegion(
      "c", x: 40, y: 402, width: 240,
      text: "network and reduced inflammation in all participants.")
    #expect(linked([c, a, b]).allSatisfy { $0.continuationGroup == ["a", "b", "c"] })
  }

  @Test func twoShortBoxesCanTogetherFormBodyText() {
    let a = boxRegion("a", x: 35, y: 600, width: 120, text: "The experimental treatment was")
    let b = boxRegion("b", x: 35, y: 551, width: 120, text: "associated with changes in the")
    let c = boxRegion(
      "c", x: 180, y: 600, width: 180,
      text: "cellular network and the surrounding tissue.")
    #expect(linked([c, a, b]).allSatisfy { $0.continuationGroup == ["a", "b", "c"] })
  }

  @Test func abbreviationPeriodAndBracketDoNotEndSentence() {
    let a = region(
      "a", page: 0, y: 80,
      text: "The intervention affected several biological pathways, e.g.")
    #expect(linked([a, pair[1]]).allSatisfy { $0.continuationGroup == ["a", "b"] })
    let open = region(
      "a", page: 0, y: 80,
      text: "We observed a significant effect in the first group (")
    let next = region(
      "b", page: 1, y: 670,
      text: "Control versus Treatment, adjusted for baseline differences).")
    #expect(linked([open, next]).allSatisfy { $0.continuationGroup == ["a", "b"] })
  }

  @Test func repeatedBodyIsNotDiscardedAsRunningHeader() {
    let text = "the cellular network and reduced inflammation in all participants."
    let repeated = region("repeat", page: 2, y: 400, text: text)
    let b = region("b", page: 1, y: 400, text: text)
    #expect(
      linked([pair[0], b, repeated]).first { $0.id == "a" }?.continuationGroup == ["a", "b"])
  }

  @Test func scannedBodyCanContinueButFigureOCRCannot() {
    let a = boxRegion(
      "a", page: 0, x: 50, y: 100, width: 450,
      text: pair[0].sourceText, kind: .imageOCR)
    let b = boxRegion(
      "b", page: 1, x: 50, y: 650, width: 450,
      text: pair[1].sourceText, kind: .imageOCR)
    #expect(linked([a, b]).allSatisfy { $0.continuationGroup == ["a", "b"] })
    let native = region(
      "body", page: 1, y: 500,
      text: "An independent native paragraph ends here.")
    #expect(linked([a, b, native]).allSatisfy { $0.continuationGroup == nil })
  }

  @Test func smallFootnoteDoesNotBecomeBodyContinuation() {
    let body = boxRegion(
      "a", x: 50, y: 300, width: 450,
      text:
        "The treatment improved the long-term stability of the cellular network and the surrounding"
    )
    let footnote = boxRegion(
      "footnote", x: 50, y: 90, width: 450,
      text: "this footnote contains supplementary information about the experimental setup.",
      font: 7)
    #expect(
      linked([body, footnote, pair[1]]).first { $0.id == "a" }?.continuationGroup == ["a", "b"])
    #expect(
      linked([body, footnote, pair[1]]).first { $0.id == "footnote" }?.continuationGroup == nil)
  }

  @Test func unrelatedRegionsNeverHaveTheirTranslationMoved() {
    let input = ["a": "这是与下一段无关的完整文字内容", "b": "开头；后面是另外一段文字，与上一段无关。"]
    #expect(
      TranslationService.alignContinuationBoundaries(input, regions: pair, target: "zh") == input)
  }

  @Test(arguments: [1, 4])
  func partialResumeRetranslatesWholePairAndCheckpointsAtomically(concurrency: Int) async throws {
    let regions =
      linked(pair) + [
        region(
          "c", page: 1, y: 350,
          text: "A later independent paragraph with its own complete sentence.")
      ]
    let probe = ContinuityProbe(omitFirstResponsePart: true)
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: concurrency,
      requestSender: { try await probe.send($0) })
    let result = try await service.translateRegions(
      regions, source: "en", target: "zh", glossary: "",
      existingTranslations: ["a": "old half"], checkpoint: { await probe.save($0) })
    #expect(result == ["a": "译文-a", "b": "译文-b", "c": "译文-c"])
    let state = await probe.snapshot()
    #expect(state.requests == [["a", "b"], ["a", "b"], ["c"]])
    #expect(state.checkpoints.count == 2)
    #expect(state.checkpoints.allSatisfy { ($0["a"] == nil) == ($0["b"] == nil) })
    #expect(state.sawContinuityInstruction)
  }

  @Test func completePairIsReusedAndTotalMeasuresTextRatherThanFarthestPage() async throws {
    let long = region("long", page: 0, y: 80, text: String(repeating: "word ", count: 200))
    let short = region("short", page: 14, y: 80, text: "label")
    let probe = ContinuityProbe()
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: 4,
      requestSender: { try await probe.send($0) })
    _ = try await ProcessingProgress.$reporter.withValue(
      { await probe.record($0) },
      operation: {
        try await service.translateRegions(
          [long, short], source: "en", target: "zh", glossary: "",
          existingTranslations: ["short": "标签"])
      })
    let state = await probe.snapshot()
    let totals = state.progress.filter { $0.id == "translation-total" }
    #expect(totals.first?.title.contains("已完成 1/2 页") == true)
    #expect(totals.first?.title.contains("复用 1 页") == true)
    #expect(try #require(totals.first?.fraction) < 0.01)
    #expect(totals.last?.fraction == 1)
    #expect(zip(totals, totals.dropFirst()).allSatisfy { $0.fraction! <= $1.fraction! })
    let cached = ["a": "甲", "b": "乙"]
    let output = try await service.translateRegions(
      linked(pair), source: "en", target: "zh", glossary: "",
      existingTranslations: cached)
    #expect(output == cached)
    #expect(await probe.snapshot().requests == [["long"]])
  }

  @Test func plainTextOutputAlsoJoinsCrossPageSentences() async throws {
    let probe = ContinuityProbe()
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: 4,
      requestSender: { try await probe.send($0) })
    let result = try await service.translatePages(
      pair.map(\.sourceText), source: "en", target: "zh", glossary: "")
    #expect(result == ["译文-page-0", "译文-page-1"])
    #expect(await probe.snapshot().requests == [["page-0", "page-1"]])
  }

  @Test func missingContinuationNeverCommitsHalfASentence() async throws {
    let probe = ContinuityProbe(alwaysOmitPart: true)
    let service = TranslationService(
      provider: "deepseek", apiKey: "test-key", pageConcurrency: 4,
      requestSender: { try await probe.send($0) })
    await #expect(throws: (any Error).self) {
      _ = try await service.translateRegions(
        linked(pair), source: "en", target: "zh", glossary: "",
        checkpoint: { await probe.save($0) })
    }
    let state = await probe.snapshot()
    #expect(state.requests.count == 2)
    #expect(state.checkpoints.isEmpty)
  }
}

private actor ContinuityProbe {
  struct State: Sendable {
    var requests: [[String]] = []
    var checkpoints: [[String: String]] = []
    var progress: [TaskProgressLine] = []
    var sawContinuityInstruction = false
  }
  private var state = State()
  private let omitFirstResponsePart: Bool
  private let alwaysOmitPart: Bool
  init(omitFirstResponsePart: Bool = false, alwaysOmitPart: Bool = false) {
    self.omitFirstResponsePart = omitFirstResponsePart
    self.alwaysOmitPart = alwaysOmitPart
  }
  func snapshot() -> State { state }
  func save(_ result: [String: String]) { state.checkpoints.append(result) }
  func record(_ progress: TaskProgressLine) { state.progress.append(progress) }
  func send(_ request: URLRequest) throws -> (Data, URLResponse) {
    let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
    let messages = try #require(body["messages"] as? [[String: String]])
    let input = try #require(
      JSONSerialization.jsonObject(with: Data(messages.last!["content"]!.utf8)) as? [String: Any])
    let items = try #require(input["items"] as? [[String: String]])
    let ids = items.map { $0["id"]! }
    state.requests.append(ids)
    if ids.count > 1 { state.sawContinuityInstruction = messages[0]["content"]!.contains("跨页连续正文") }
    let returned =
      alwaysOmitPart || (omitFirstResponsePart && state.requests.count == 1)
      ? Array(ids.prefix(1)) : ids
    let content = try JSONSerialization.data(withJSONObject: [
      "items": returned.map { ["id": $0, "text": "译文-" + $0] }
    ])
    let response = try JSONSerialization.data(withJSONObject: [
      "choices": [["message": ["content": String(decoding: content, as: UTF8.self)]]]
    ])
    return (
      response,
      try #require(
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil))
    )
  }
}
