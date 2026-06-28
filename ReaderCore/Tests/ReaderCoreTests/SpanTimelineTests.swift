import XCTest
@testable import ReaderCore

/// `SpanTimeline.index(at:)` is the highlight lookup lifted out of the sync
/// spike. These pin its boundary behavior (start-inclusive, stays on last,
/// nil during leading silence) so the reader playback loop stays correct.
final class SpanTimelineTests: XCTestCase {
    private func span(_ i: Int, _ start: Double, _ end: Double) -> TokenSpan {
        TokenSpan(index: i, surface: "x", reading: nil, start: start, end: end, matchedChars: 1)
    }

    func testEmptyTimeline() {
        let t = SpanTimeline([])
        XCTAssertNil(t.index(at: 0))
        XCTAssertEqual(t.duration, 0)
        XCTAssertTrue(t.isEmpty)
    }

    func testIndexAtPicksRightmostStartedToken() {
        let t = SpanTimeline([span(0, 0.0, 0.5), span(1, 0.5, 1.0), span(2, 1.0, 1.5)])
        XCTAssertEqual(t.index(at: 0.0), 0)
        XCTAssertEqual(t.index(at: 0.4), 0)
        XCTAssertEqual(t.index(at: 0.5), 1)   // boundary is start-inclusive
        XCTAssertEqual(t.index(at: 1.2), 2)
        XCTAssertEqual(t.index(at: 99), 2)    // past the end stays on the last token
    }

    func testNilBeforeFirstStart() {
        let t = SpanTimeline([span(0, 0.3, 0.6)])
        XCTAssertNil(t.index(at: 0.0))        // leading silence — no highlight yet
        XCTAssertEqual(t.index(at: 0.3), 0)
    }

    func testDuration() {
        let t = SpanTimeline([span(0, 0.0, 0.5), span(1, 0.5, 1.25)])
        XCTAssertEqual(t.duration, 1.25, accuracy: 1e-9)
    }

    /// The render-only builder (free tier / pre-synthesis) carries surface, reading,
    /// dictionaryForm and index from the tokens with zero timing — so the surface
    /// draws furigana + tap-to-define without any audio.
    func testUntimedBuilderPreservesTokenFieldsWithZeroTiming() {
        let tokens = [
            Token(surface: "生まれた", reading: "うまれた", dictionaryForm: "生まれる"),
            Token(surface: "。", reading: nil, dictionaryForm: nil),
        ]
        let t = SpanTimeline(untimedTokens: tokens)
        XCTAssertEqual(t.spans.count, 2)
        XCTAssertEqual(t.spans[0].index, 0)
        XCTAssertEqual(t.spans[0].surface, "生まれた")
        XCTAssertEqual(t.spans[0].reading, "うまれた")
        XCTAssertEqual(t.spans[0].dictionaryForm, "生まれる")
        XCTAssertEqual(t.spans[1].index, 1)
        XCTAssertNil(t.spans[1].reading)
        XCTAssertEqual(t.duration, 0)
        XCTAssertTrue(t.spans.allSatisfy { $0.start == 0 && $0.end == 0 && $0.matchedChars == 0 })
    }
}
