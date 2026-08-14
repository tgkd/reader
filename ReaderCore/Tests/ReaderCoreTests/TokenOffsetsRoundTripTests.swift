import XCTest
@testable import ReaderCore

final class TokenOffsetsRoundTripTests: XCTestCase {
    private func spans(for text: String) throws -> [TokenSpan] {
        try MeCabTokenizer().tokenize(text).enumerated().map { i, token in
            TokenSpan(index: i, surface: token.surface, reading: token.reading,
                      dictionaryForm: token.dictionaryForm,
                      start: Double(i), end: Double(i + 1), matchedChars: token.surface.count)
        }
    }

    private func assertRoundTrips(_ text: String,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let spans = try spans(for: text)
        XCTAssertFalse(spans.isEmpty, file: file, line: line)

        for i in spans.indices {
            let offset = TokenOffsets.charOffset(ofToken: i, in: spans)
            XCTAssertEqual(TokenOffsets.token(atCharOffset: offset, in: spans), i,
                           "token \(i) (\(spans[i].surface)) did not round-trip through \(offset)",
                           file: file, line: line)
        }

        let total = spans.reduce(0) { $0 + $1.surface.count }
        XCTAssertEqual(total, Normalize.nfkc(text).count,
                       "offsets are only meaningful if the surfaces tile the text exactly",
                       file: file, line: line)
        XCTAssertEqual(TokenOffsets.charOffset(ofToken: spans.count, in: spans), total,
                       file: file, line: line)
    }

    func testCleanText() throws {
        try assertRoundTrips("吾輩は猫である。名前はまだ無い。")
    }

    func testTextWithVariationSelectors() throws {
        try assertRoundTrips("葛\u{E0100}城さんは辻\u{E0101}さんと歩いた。")
    }

    func testTextWithParagraphsAndACombiningMark() throws {
        try assertRoundTrips("第一章\r\n\n　が\u{3099}っこうへ行く。")
    }
}
