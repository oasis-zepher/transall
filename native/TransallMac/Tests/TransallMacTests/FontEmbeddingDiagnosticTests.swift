import AppKit
import CoreText
import Foundation
import Testing

@testable import TransallMac

// Temporary: prints font facts from the CI runner. Remove after the macOS 26 font fix.
@Suite("Font embedding diagnostics")
@MainActor
struct FontEmbeddingDiagnosticTests {
  @Test func printCJKFontFacts() throws {
    print("DIAG os:", ProcessInfo.processInfo.operatingSystemVersionString)
    let base = CTFontCreateWithName("Helvetica" as CFString, 20, nil)
    let fallback = CTFontCreateForString(base, "中文" as CFString, CFRange(location: 0, length: 2))
    let candidates = [
      CTFontCopyPostScriptName(fallback) as String, "PingFangSC-Regular", "HiraginoSansGB-W3",
      "STHeitiSC-Light", "STSongti-SC-Regular", "Songti-SC-Regular",
    ]
    let input = try PDFDirectEditingTests().fixture()
    let block = try #require(
      PDFContentEditor.blocks(in: input, page: 0).first { $0.text.contains("Edit this text") })
    for name in candidates {
      let font = CTFontCreateWithName(name as CFString, 20, nil)
      let actual = CTFontCopyPostScriptName(font) as String
      let url = (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.path ?? "no url"
      var tags: [String] = []
      if let tables = CTFontCopyAvailableTables(font, CTFontTableOptions(rawValue: 0)) {
        tags = (0..<CFArrayGetCount(tables)).map {
          let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tables, $0)))
          return String(bytes: [24, 16, 8, 0].map { UInt8((tag >> $0) & 255) }, encoding: .ascii)
            ?? "?"
        }
      }
      var draft = PDFTextDraft(block: block)
      draft.text = "中文输入"
      draft.fontName = actual
      let outcome: String
      do {
        _ = try PDFContentEditor.apply(draft, to: input, page: 0)
        outcome = "embed ok"
      } catch {
        outcome = "embed failed: \(error.localizedDescription)"
      }
      print(
        "DIAG font \(name) -> \(actual) | \(url) | \(tags.sorted().joined(separator: " ")) | \(outcome)"
      )
    }
  }
}
