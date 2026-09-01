import XCTest
@testable import ReaderCore

final class ChapterSplitTests: XCTestCase {
    func testShortChapterIsUnchanged() {
        let ch = Chapter(title: "章", text: "吾輩は猫である。名前はまだ無い。")
        let parts = ch.splitToRenderable(maxChars: 4_000)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].text, ch.text)
        XCTAssertEqual(parts[0].title, "章")
    }

    func testLongChapterSplitsIntoBoundedLosslessParts() {
        let para = "吾輩は猫である。名前はまだ無い。どこで生れたか頓と見当がつかぬ。\n\n"
        let text = String(repeating: para, count: 50)
        let ch = Chapter(title: "本文", text: text)

        let parts = ch.splitToRenderable(maxChars: 300, hardMax: 420)
        XCTAssertGreaterThan(parts.count, 1, "an oversized chapter must split")
        XCTAssertTrue(parts.allSatisfy { $0.text.count <= 420 },
                      "each part must be within the cap; got \(parts.map(\.text.count))")
        XCTAssertEqual(parts.map(\.text).joined(), text)
        XCTAssertEqual(parts.first?.title, "本文 (1)")
        XCTAssertEqual(parts.last?.title, "本文 (\(parts.count))")
    }

    func testUntitledChapterStaysUntitledWhenSplit() {
        let text = String(repeating: "あいうえお。", count: 200)
        let parts = Chapter(title: nil, text: text).splitToRenderable(maxChars: 200, hardMax: 280)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertNil(parts.first?.title)
    }
}
