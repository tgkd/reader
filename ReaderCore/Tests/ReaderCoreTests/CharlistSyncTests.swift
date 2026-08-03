import XCTest
@testable import ReaderCore

/// Sync regression for the SHAPE of text that reads worst: a character-list page —
/// short lines separated by blank lines, full-width name spaces, bracket glyphs.
/// Everything else in the suite is continuous prose, and blank-line pauses are
/// where a drifting highlight was suspected to come from (reported 2026-08-03).
///
/// `fixtures/charlist.json` is a real `eleven_v3` + Shizuka capture. The expected
/// times below are NOT taken from the alignment — they were measured on the
/// fixture's own mp3 with `ffmpeg silencedetect`, so this asserts the timeline
/// against the AUDIO, not against itself:
///
///     10.08–10.88 s   ユーフォニアム is spoken
///     10.88–12.32 s   the pause on the 。 after it
///     14.16–15.00 s   東京 is spoken
final class CharlistSyncTests: XCTestCase {

    private struct Fixture: Decodable {
        let text: String
        let alignment: Alignment
    }

    private func loadTimeline() throws -> (SpanTimeline, [TokenSpan]) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/charlist.json")
        let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let tokens = try MeCabTokenizer().tokenize(fx.text)

        // The two invariants the fold rests on: the tokenizer loses nothing (gap
        // tokens carry the blank lines), and the alignment indexes that same string.
        XCTAssertEqual(tokens.map(\.surface).joined(), Normalize.nfkc(fx.text))
        XCTAssertEqual(fx.alignment.characters.joined(), Normalize.nfkc(fx.text))

        let spans = CharTokenMapper.map(tokens: tokens, alignment: fx.alignment)
        return (SpanTimeline(spans), spans)
    }

    /// The highlight must name the word the listener is hearing.
    func testHighlightTracksTheSpokenWord() throws {
        let (timeline, spans) = try loadTimeline()
        func surface(at t: Double) -> String? {
            timeline.index(at: t).flatMap { spans.indices.contains($0) ? spans[$0].surface : nil }
        }
        XCTAssertEqual(surface(at: 10.5), "ユーフォニアム")
        XCTAssertEqual(surface(at: 11.5), "。")          // the pause after it
        XCTAssertEqual(surface(at: 14.5), "東京")
    }

    /// The specific misreading in the report: 東京 highlighted while ユーフォニアム
    /// is still being spoken. Those two must not overlap by seconds.
    func testTokyoDoesNotStartWhileEuphoniumIsStillSpoken() throws {
        let (_, spans) = try loadTimeline()
        let euph = try XCTUnwrap(spans.first { $0.surface == "ユーフォニアム" })
        let tokyo = try XCTUnwrap(spans.first { $0.surface == "東京" })
        XCTAssertGreaterThan(tokyo.start, euph.end,
                             "東京 starts before ユーフォニアム has finished — the reported drift")
    }

    /// Blank lines survive tokenization as gap tokens and carry the pause the API
    /// charges to them, rather than being dropped and skewing everything after.
    func testBlankLinesAreTimedGapTokens() throws {
        let (_, spans) = try loadTimeline()
        let gaps = spans.filter { $0.surface.contains("\n") }
        XCTAssertFalse(gaps.isEmpty, "blank lines were dropped by the tokenizer")
        XCTAssertTrue(gaps.allSatisfy { $0.matchedChars > 0 },
                      "a blank-line gap matched no alignment character")
    }
}
