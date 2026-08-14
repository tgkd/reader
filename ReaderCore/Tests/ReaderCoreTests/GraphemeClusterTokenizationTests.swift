import XCTest
@testable import ReaderCore

final class GraphemeClusterTokenizationTests: XCTestCase {
    private func tokenize(_ input: String) throws -> [Token] {
        try MeCabTokenizer().tokenize(input)
    }

    private func assertInvariants(_ tokens: [Token], _ input: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        let normalized = Normalize.nfkc(input)
        XCTAssertEqual(tokens.map(\.surface).joined(), normalized,
                       "surfaces must rejoin the normalized text", file: file, line: line)
        XCTAssertEqual(tokens.reduce(0) { $0 + $1.surface.count }, normalized.count,
                       "surface counts must sum to the character count", file: file, line: line)
    }

    func testVariationSelectorKeepsTheCompoundAndItsReading() throws {
        let input = "葛\u{E0100}城さんは辻\u{E0101}さんと歩いた。"
        let tokens = try tokenize(input)
        assertInvariants(tokens, input)

        XCTAssertEqual(tokens.map(\.surface),
                       ["葛\u{E0100}城", "さん", "は", "辻\u{E0101}", "さん", "と", "歩い", "た", "。"],
                       "the selector must ride with its base kanji instead of splitting the word")
        XCTAssertEqual(tokens[0].reading, "かつらぎ",
                       "unrepaired, the selector breaks 葛城 into 葛 + 城/ジョウ")
        XCTAssertEqual(tokens[0].dictionaryForm, "葛城")
        XCTAssertEqual(tokens[3].reading, "つじ")
    }

    func testVariationSelectorSurfaceStillMatchesPublisherRuby() throws {
        let input = "葛\u{E0100}城さんは歩いた。"
        let tokens = try tokenize(input)
        let ruby = [SourceReading(start: 0, length: 2, surface: "葛\u{E0100}城", reading: "かつらぎ")]

        let readings = SourceReadingOverlay.bookReadings(ruby, tokens: tokens, text: input)
        XCTAssertEqual(readings.compactMap { $0 }, ["かつらぎ"],
                       """
                       the book's own ruby must still attach: bookReadings gates on \
                       Normalize.nfkc(surface) == token.surface, so a surface stripped of its \
                       selector would silently stop matching
                       """)
    }

    func testStrayCombiningMarkKeepsTheTextAdditive() throws {
        let input = "が\u{3099}っこうへ行く。"
        let tokens = try tokenize(input)
        assertInvariants(tokens, input)

        let marked = tokens.filter { $0.surface.unicodeScalars.contains("\u{3099}") }
        XCTAssertEqual(marked.count, 1, "the cluster must land in exactly one token")
        XCTAssertEqual(marked.first?.surface.first, Character("が\u{3099}"),
                       "a node boundary inside a grapheme cluster must snap outward, not split it")
        XCTAssertNil(marked.first?.reading,
                     "a widened surface is no longer what the node's reading describes")
    }

    func testCarriageReturnLineFeedSurvivesAsOneCharacter() throws {
        let input = "第一章\r\n吾輩は猫である。"
        let tokens = try tokenize(input)
        assertInvariants(tokens, input)
        XCTAssertTrue(tokens.contains { $0.surface.contains("\r\n") },
                      "CRLF is one Character and two scalars; it must not be split")
    }

    func testCleanTextIsUnaffectedByEitherRepair() throws {
        let input = "吾輩は猫である。\n\n　名前はまだ無い。"
        let tokens = try tokenize(input)
        assertInvariants(tokens, input)
        XCTAssertEqual(tokens.first { $0.surface == "吾輩" }?.reading, "わがはい")
    }
}
