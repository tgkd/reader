import XCTest
import ReaderCore
@testable import Reader

/// Exercises the real `TextImporter` (whole file → one chapter) across the
/// encodings `JapaneseTextDecoder` sniffs, plus the empty-input error case.
final class TextImporterTests: XCTestCase {
    private let sample = "吾輩は猫である。\n名前はまだ無い。"

    private func text(_ url: URL) async throws -> String {
        let chapters = try await TextImporter(url: url).chapters()
        XCTAssertEqual(chapters.count, 1)   // the whole file is a single chapter
        return chapters[0].text
    }

    func testUTF8() async throws {
        let url = Fixture.textFile(sample, encoding: .utf8)
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
    }

    func testShiftJIS() async throws {
        let url = Fixture.textFile(sample, encoding: .shiftJIS)
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
    }

    func testEUCJP() async throws {
        let url = Fixture.textFile(sample, encoding: .japaneseEUC)
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
    }

    func testUTF8BOMIsStripped() async throws {
        let url = Fixture.textFile(sample, encoding: .utf8, bom: [0xEF, 0xBB, 0xBF])
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
        XCTAssertFalse(decoded.unicodeScalars.contains("\u{FEFF}"))   // BOM gone
    }

    func testTextExtensionAlsoWorks() async throws {
        let url = Fixture.textFile(sample, encoding: .utf8, ext: "text")
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
    }

    func testWhitespaceOnlyThrowsUnreadable() async {
        let url = Fixture.textFile("   \n\t  \n", encoding: .utf8)
        do {
            _ = try await TextImporter(url: url).chapters()
            XCTFail("expected unreadable")
        } catch {
            XCTAssertEqual(error as? ImportError, .unreadable)
        }
    }

    // MARK: - Markdown (.md routes here with stripMarkdown)

    /// End-to-end: a .md file imports through `Importer` with syntax stripped
    /// and prose (incl. Japanese) intact.
    func testMarkdownFileImportsStripped() async throws {
        let md = """
        # 第一章

        これは**大事な**文章です。[青空文庫](https://aozora.gr.jp)より。

        - 猫
        - 犬
        """
        let url = Fixture.renamed(Fixture.textFile(md, encoding: .utf8, ext: "md"), to: "メモ.md")
        let doc = try await Importer.document(from: url)
        XCTAssertEqual(doc.title, "メモ")
        XCTAssertEqual(doc.chapters.count, 1)
        XCTAssertEqual(doc.chapters[0].text, """
        第一章

        これは大事な文章です。青空文庫より。

        猫
        犬
        """)
    }

    func testMarkdownStripInlineAndBlockConstructs() {
        XCTAssertEqual(MarkdownStrip.plainText("## 見出し"), "見出し")
        XCTAssertEqual(MarkdownStrip.plainText("> 引用文"), "引用文")
        XCTAssertEqual(MarkdownStrip.plainText("1. 一つ目\n2) 二つ目"), "一つ目\n二つ目")
        XCTAssertEqual(MarkdownStrip.plainText("*強調*と__太字__と`コード`"), "強調と太字とコード")
        XCTAssertEqual(MarkdownStrip.plainText("![挿絵](img.png)を見る"), "挿絵を見る")
        XCTAssertEqual(MarkdownStrip.plainText("```\nlet x = 1\n```\n本文"), "let x = 1\n本文")
        XCTAssertEqual(MarkdownStrip.plainText("上\n---\n下"), "上\n下")
        // Plain prose — including 3.14-style numbers mid-line — passes through.
        XCTAssertEqual(MarkdownStrip.plainText("価格は3.14ドルです。"), "価格は3.14ドルです。")
    }

    /// A markdown file that is ONLY syntax (fences/rules) strips to nothing →
    /// the standard unreadable error, not an empty book.
    func testMarkdownOnlySyntaxThrowsUnreadable() async {
        let url = Fixture.textFile("```\n```\n---\n", encoding: .utf8, ext: "md")
        do {
            _ = try await Importer.document(from: url)
            XCTFail("expected unreadable")
        } catch {
            XCTAssertEqual(error as? ImportError, .unreadable)
        }
    }
}

/// Title derivation for the paste-text import (the only paste logic that isn't
/// UI glue): first non-empty line, trimmed, capped.
final class PasteTitleTests: XCTestCase {
    @MainActor func testFirstLineBecomesTitle() {
        XCTAssertEqual(AppModel.defaultPasteTitle(from: "吾輩は猫である\n名前はまだ無い"), "吾輩は猫である")
    }

    @MainActor func testLongFirstLineIsCapped() {
        let long = String(repeating: "あ", count: 100)
        XCTAssertEqual(AppModel.defaultPasteTitle(from: long).count, 24)
    }

    @MainActor func testLeadingWhitespaceTrimmed() {
        XCTAssertEqual(AppModel.defaultPasteTitle(from: "  タイトル  \n本文"), "タイトル")
    }
}
