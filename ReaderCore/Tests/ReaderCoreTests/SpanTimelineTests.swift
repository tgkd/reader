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

    /// A chapter highlighted WHILE it is generated folds the whole chapter's tokens
    /// against a partial alignment, so every token past the frontier is interpolated
    /// to one identical start. The lookup must stop at the last TIMED token instead
    /// of answering with the last token of the chapter — that jump is what threw the
    /// highlight to the end of the text mid-playback.
    func testDoesNotRunPastTheTimedFrontier() {
        let timed = [span(0, 0.0, 0.5), span(1, 0.5, 1.0)]
        // What CharTokenMapper produces for the ungenerated tail: no matched chars,
        // interval collapsed onto the last timed end.
        let tail = (2..<6).map { i in
            TokenSpan(index: i, surface: "x", reading: nil, start: 1.0, end: 1.0, matchedChars: 0)
        }
        let t = SpanTimeline(timed + tail)
        XCTAssertEqual(t.index(at: 0.9), 1)
        XCTAssertEqual(t.index(at: 1.0), 1)    // AT the frontier: hold, don't jump
        XCTAssertEqual(t.index(at: 99), 1)     // and stay held however far past
        XCTAssertEqual(t.timedExtent, 1.0, accuracy: 1e-9)
    }

    /// Interpolated tokens BETWEEN timed ones keep their intervals — the clamp is a
    /// tail rule, not a ban on interpolation.
    func testInteriorInterpolatedTokensStaySelectable() {
        let t = SpanTimeline([
            span(0, 0.0, 0.5),
            TokenSpan(index: 1, surface: "x", reading: nil, start: 0.5, end: 0.8, matchedChars: 0),
            span(2, 0.8, 1.2),
        ])
        XCTAssertEqual(t.index(at: 0.6), 1)
        XCTAssertEqual(t.index(at: 1.0), 2)
    }

    /// No timings at all (the render-only timeline) means no highlight, rather than
    /// every token sharing start 0 and the search answering with the last one.
    func testUntimedTimelineHasNoActiveToken() {
        let t = SpanTimeline(untimedTokens: [Token(surface: "猫"), Token(surface: "。")])
        XCTAssertNil(t.index(at: 0))
        XCTAssertNil(t.index(at: 5))
        XCTAssertEqual(t.timedExtent, 0)
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
