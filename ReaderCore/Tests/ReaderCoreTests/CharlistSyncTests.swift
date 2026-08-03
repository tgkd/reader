import XCTest
@testable import ReaderCore

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

        XCTAssertEqual(tokens.map(\.surface).joined(), Normalize.nfkc(fx.text))
        XCTAssertEqual(fx.alignment.characters.joined(), Normalize.nfkc(fx.text))

        let spans = CharTokenMapper.map(tokens: tokens, alignment: fx.alignment)
        return (SpanTimeline(spans), spans)
    }

    func testHighlightTracksTheSpokenWord() throws {
        let (timeline, spans) = try loadTimeline()
        func surface(at t: Double) -> String? {
            timeline.index(at: t).flatMap { spans.indices.contains($0) ? spans[$0].surface : nil }
        }
        XCTAssertEqual(surface(at: 10.5), "ユーフォニアム")
        XCTAssertEqual(surface(at: 11.5), "。")
        XCTAssertEqual(surface(at: 14.5), "東京")
    }

    func testTokyoDoesNotStartWhileEuphoniumIsStillSpoken() throws {
        let (_, spans) = try loadTimeline()
        let euph = try XCTUnwrap(spans.first { $0.surface == "ユーフォニアム" })
        let tokyo = try XCTUnwrap(spans.first { $0.surface == "東京" })
        XCTAssertGreaterThan(tokyo.start, euph.end,
                             "東京 starts before ユーフォニアム has finished — the reported drift")
    }

    func testBlankLinesAreTimedGapTokens() throws {
        let (_, spans) = try loadTimeline()
        let gaps = spans.filter { $0.surface.contains("\n") }
        XCTAssertFalse(gaps.isEmpty, "blank lines were dropped by the tokenizer")
        XCTAssertTrue(gaps.allSatisfy { $0.matchedChars > 0 },
                      "a blank-line gap matched no alignment character")
    }
}
