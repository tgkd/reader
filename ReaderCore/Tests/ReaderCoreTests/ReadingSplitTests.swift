import XCTest
@testable import ReaderCore

final class ReadingSplitTests: XCTestCase {
    private func paragraphs(_ count: Int, sentencesEach: Int = 4) -> String {
        (0..<count).map { p in
            (0..<sentencesEach).map { s in "　これは第\(p)段落の第\(s)文であり、長さを稼ぐための本文です。" }
                .joined() + "\n"
        }.joined()
    }

    func testShortTextIsNotSplit() {
        let text = paragraphs(1)
        XCTAssertEqual(Chunker.splitForReading(text, target: 1_000, hardMax: 1_400), [text])
    }

    func testSplitIsLossless() {
        let text = paragraphs(30)
        let parts = Chunker.splitForReading(text, target: 1_000, hardMax: 1_400)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.joined(), text)
    }

    func testNoBlockExceedsTheHardMaximum() {
        let parts = Chunker.splitForReading(paragraphs(30), target: 1_000, hardMax: 1_400)
        for part in parts { XCTAssertLessThanOrEqual(part.count, 1_400) }
    }

    func testEveryBlockEndsAtAParagraphBreak() {
        let parts = Chunker.splitForReading(paragraphs(30), target: 1_000, hardMax: 1_400)
        for part in parts.dropLast() {
            XCTAssertEqual(part.last, "\n", "block should end at a paragraph break")
        }
    }

    func testAParagraphLongerThanTheMaximumFallsBackToSentences() {
        let long = String(repeating: "これは非常に長い一文の連続である。", count: 200) + "\n"
        let parts = Chunker.splitForReading(long, target: 1_000, hardMax: 1_400)
        XCTAssertEqual(parts.joined(), long)
        for part in parts.dropLast() {
            XCTAssertTrue(part.hasSuffix("。") || part.hasSuffix("\n"),
                          "sentence fallback should still cut at a terminator")
            XCTAssertLessThanOrEqual(part.count, 1_400)
        }
    }

    func testASentenceLongerThanTheMaximumIsHardSplit() {
        let runOn = String(repeating: "あ", count: 3_000) + "。"
        let parts = Chunker.splitForReading(runOn, target: 1_000, hardMax: 1_400)
        XCTAssertEqual(parts.joined(), runOn)
        for part in parts { XCTAssertLessThanOrEqual(part.count, 1_400) }
    }

    func testChapterSplitKeepsTheWholeTextAndFitsOneRequest() {
        let chapter = Chapter(title: "章", text: paragraphs(30))
        let parts = chapter.splitToRenderable()
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.map(\.text).joined(), chapter.text)
        for part in parts {
            XCTAssertLessThanOrEqual(part.text.count, SynthesisLimits.maxRequestChars,
                                     "a displayed chapter must be one TTS request")
        }
        XCTAssertEqual(parts.first?.title, "章 (1)")
    }
}
