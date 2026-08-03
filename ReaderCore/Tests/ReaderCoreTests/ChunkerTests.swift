import XCTest
@testable import ReaderCore

final class ChunkerTests: XCTestCase {
    func testEmptyYieldsNoSegments() {
        XCTAssertEqual(Chunker.split(""), [])
    }

    func testShortTextStaysOneSegment() {
        let t = "吾輩は猫である。名前はまだ無い。"
        XCTAssertEqual(Chunker.split(t, maxChars: 100), [t])
    }

    func testLosslessReconstruction() {
        let t = "メロスは激怒した。必ず、かの邪智暴虐の王を除かなければならぬと決意した。\n"
            + "「行こう」と彼は言った。「もう時間がない。」今日は2026年6月27日であった"
        for cap in [4, 7, 10, 13, 20, 50] {
            let segs = Chunker.split(t, maxChars: cap)
            XCTAssertEqual(segs.joined(), t, "lossless broke at cap=\(cap)")
        }
    }

    func testEverySegmentUnderCap() {
        let t = String(repeating: "あいうえお。", count: 400)
        let cap = 50
        for seg in Chunker.split(t, maxChars: cap) {
            XCTAssertLessThanOrEqual(seg.count, cap)
        }
    }

    func testSplitsOnSentenceBoundary() {
        let t = "一つ目の文。二つ目の文。三つ目の文。"
        let segs = Chunker.split(t, maxChars: 7)
        XCTAssertGreaterThan(segs.count, 1)
        for seg in segs.dropLast() {
            XCTAssertTrue(seg.hasSuffix("。"), "segment did not end on a sentence boundary: \(seg)")
        }
        XCTAssertEqual(segs.joined(), t)
    }

    func testOversizedSingleSentenceHardSplits() {
        let t = String(repeating: "あ", count: 25)
        let segs = Chunker.split(t, maxChars: 10)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs.map(\.count), [10, 10, 5])
        XCTAssertEqual(segs.joined(), t)
    }

    func testCountsByGrapheme() {
        let t = String(repeating: "𠮷", count: 12)
        let segs = Chunker.split(t, maxChars: 5)
        XCTAssertEqual(segs.map(\.count), [5, 5, 2])
        XCTAssertEqual(segs.joined(), t)
    }
}
