import XCTest
@testable import ReaderCore

/// `Chunker.split` cuts a long chapter into under-cap TTS segments. The
/// load-bearing property is **losslessness** — the segments must concatenate back
/// to the exact input, or the stitched alignment would stop reconstructing the
/// text and `CharTokenMapper` / furigana would drift. These pin that plus the cap
/// and boundary behavior.
final class ChunkerTests: XCTestCase {

    func testEmptyYieldsNoSegments() {
        XCTAssertEqual(Chunker.split(""), [])
    }

    func testShortTextStaysOneSegment() {
        let t = "吾輩は猫である。名前はまだ無い。"
        XCTAssertEqual(Chunker.split(t, maxChars: 100), [t])
    }

    func testLosslessReconstruction() {
        // A mix of sentences, dialogue, digits, newlines, and a trailing fragment
        // with no terminator — the segments must rejoin to exactly the input.
        let t = "メロスは激怒した。必ず、かの邪智暴虐の王を除かなければならぬと決意した。\n"
            + "「行こう」と彼は言った。「もう時間がない。」今日は2026年6月27日であった"
        for cap in [4, 7, 10, 13, 20, 50] {
            let segs = Chunker.split(t, maxChars: cap)
            XCTAssertEqual(segs.joined(), t, "lossless broke at cap=\(cap)")
        }
    }

    func testEverySegmentUnderCap() {
        let t = String(repeating: "あいうえお。", count: 400) // 2400 chars
        let cap = 50
        for seg in Chunker.split(t, maxChars: cap) {
            XCTAssertLessThanOrEqual(seg.count, cap)
        }
    }

    func testSplitsOnSentenceBoundary() {
        // Three sentences, cap that fits two. The break should land on a 。, never
        // mid-sentence: each non-final segment ends with a terminator.
        let t = "一つ目の文。二つ目の文。三つ目の文。"
        let segs = Chunker.split(t, maxChars: 7)
        XCTAssertGreaterThan(segs.count, 1)
        for seg in segs.dropLast() {
            XCTAssertTrue(seg.hasSuffix("。"), "segment did not end on a sentence boundary: \(seg)")
        }
        XCTAssertEqual(segs.joined(), t)
    }

    func testOversizedSingleSentenceHardSplits() {
        // One terminator-less unit longer than the cap must still be broken up,
        // and still rejoin losslessly.
        let t = String(repeating: "あ", count: 25)
        let segs = Chunker.split(t, maxChars: 10)
        XCTAssertEqual(segs.count, 3) // 10 + 10 + 5
        XCTAssertEqual(segs.map(\.count), [10, 10, 5])
        XCTAssertEqual(segs.joined(), t)
    }

    func testCountsByGrapheme() {
        // A surrogate-pair kanji is one Character; a 12-of-them string at cap 5
        // splits 5/5/2, not by UTF-16 code units.
        let t = String(repeating: "𠮷", count: 12)
        let segs = Chunker.split(t, maxChars: 5)
        XCTAssertEqual(segs.map(\.count), [5, 5, 2])
        XCTAssertEqual(segs.joined(), t)
    }
}
