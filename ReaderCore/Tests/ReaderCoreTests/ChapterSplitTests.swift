import XCTest
@testable import ReaderCore

/// `Chapter.splitToRenderable` caps chapter length so the reader's one-surface-per-
/// chapter CoreText view never exceeds the platform's max layer size (blank render)
/// or janks the main thread — while staying lossless.
final class ChapterSplitTests: XCTestCase {

    func testShortChapterIsUnchanged() {
        let ch = Chapter(title: "章", text: "吾輩は猫である。名前はまだ無い。")
        let parts = ch.splitToRenderable(maxChars: 4_000)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].text, ch.text)
        XCTAssertEqual(parts[0].title, "章")   // title untouched when not split
    }

    func testLongChapterSplitsIntoBoundedLosslessParts() {
        let para = "吾輩は猫である。名前はまだ無い。どこで生れたか頓と見当がつかぬ。\n\n"
        let text = String(repeating: para, count: 50)   // ~1500 chars
        let ch = Chapter(title: "本文", text: text)

        let parts = ch.splitToRenderable(maxChars: 300)
        XCTAssertGreaterThan(parts.count, 1, "an oversized chapter must split")
        // Every sub-chapter stays under the cap (so each renders).
        XCTAssertTrue(parts.allSatisfy { $0.text.count <= 300 },
                      "each part must be within the cap; got \(parts.map(\.text.count))")
        // Lossless: the parts concatenate back to the original text exactly.
        XCTAssertEqual(parts.map(\.text).joined(), text)
        // Titles are numbered.
        XCTAssertEqual(parts.first?.title, "本文 (1)")
        XCTAssertEqual(parts.last?.title, "本文 (\(parts.count))")
    }

    func testUntitledChapterStaysUntitledWhenSplit() {
        let text = String(repeating: "あいうえお。", count: 200)   // 1200 chars
        let parts = Chapter(title: nil, text: text).splitToRenderable(maxChars: 200)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertNil(parts.first?.title)
    }
}
