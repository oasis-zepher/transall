import AppKit
import CoreText
import Testing

@testable import TransallMac

/// On macOS 26 without the downloadable PingFang asset, CJK text fell back to
/// this system UI face. Its glyphs live in Apple's private 'hvgl' table, so
/// PDFium could not embed it and Chinese editing failed.
private let pingFangUIFace = URL(
  fileURLWithPath:
    "/System/Library/PrivateFrameworks/FontServices.framework/Resources/Reserved/PingFangUI.ttc")

@Suite("PDF font embedding")
@MainActor
struct PDFFontEmbeddingTests {
  @Test(.enabled(if: FileManager.default.fileExists(atPath: pingFangUIFace.path)))
  func systemUIFaceIsReplacedWithEmbeddableFonts() throws {
    let descriptors = try #require(
      CTFontManagerCreateFontDescriptorsFromURL(pingFangUIFace as CFURL) as? [CTFontDescriptor])
    let descriptor = try #require(descriptors.first)
    let uiFont = try #require(NSFont(descriptor: descriptor, size: 18))
    #expect(!PDFContentEditor.hasStandardOutlines(uiFont))

    let font = PDFContentEditor.embeddableFont(for: uiFont)
    #expect(PDFContentEditor.hasStandardOutlines(font))
    let chinese = CTFontCreateForString(font, "中文" as CFString, CFRange(location: 0, length: 2))
    #expect(PDFContentEditor.hasStandardOutlines(chinese))
  }

  @Test func embeddableFontKeepsAnEmbeddableChoice() {
    let helvetica = NSFont(name: "Helvetica", size: 18)!
    let font = PDFContentEditor.embeddableFont(for: helvetica)
    #expect(CTFontCopyPostScriptName(font) as String == "Helvetica")
    let chinese = CTFontCreateForString(font, "中文" as CFString, CFRange(location: 0, length: 2))
    #expect(PDFContentEditor.hasStandardOutlines(chinese))
  }
}
