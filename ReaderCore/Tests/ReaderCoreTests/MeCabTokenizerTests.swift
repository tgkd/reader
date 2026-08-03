import XCTest
@testable import ReaderCore

final class MeCabTokenizerTests: XCTestCase {
    private func makeTokenizer() throws -> MeCabTokenizer {
        try MeCabTokenizer()
    }

    private func uniform(_ s: String, dt: Double = 0.1) -> Alignment {
        let chars = s.map { String($0) }
        var starts: [Double] = [], ends: [Double] = []
        for k in 0..<chars.count { starts.append(Double(k) * dt); ends.append(Double(k + 1) * dt) }
        return Alignment(characters: chars, startTimes: starts, endTimes: ends)
    }

    func testTokenizesAndProducesReadings() throws {
        let tok = try makeTokenizer()
        let tokens = tok.tokenize("今日は良い天気ですね")

        XCTAssertGreaterThan(tokens.count, 1, "should split into multiple tokens")
        let withReadings = tokens.filter { $0.reading != nil }
        XCTAssertFalse(withReadings.isEmpty, "expected kana readings from IPADic")
        if let tenki = tokens.first(where: { $0.surface == "天気" }) {
            XCTAssertEqual(tenki.reading, "てんき")
        } else {
            XCTFail("expected a 天気 token; got \(tokens.map { $0.surface })")
        }
    }

    func testDictionaryFormGivesKanjiLemmaAndHiraganaReading() throws {
        let tok = try makeTokenizer()
        let tokens = tok.tokenize("どこで生まれたか")
        let lemma = tokens.first { $0.dictionaryForm == "生まれる" }
        XCTAssertNotNil(lemma,
            "expected a 生まれる lemma; got \(tokens.map { ($0.surface, $0.dictionaryForm ?? "·") })")
        let leakedKatakana = tokens.contains {
            ($0.reading ?? "").unicodeScalars.contains { (0x30A1...0x30F6).contains($0.value) }
        }
        XCTAssertFalse(leakedKatakana, "readings must be hiragana, got \(tokens.map { $0.reading ?? "·" })")
    }

    func testSurfacesReconstructInput() throws {
        let tok = try makeTokenizer()
        let input = "吾輩は猫である。名前はまだ無い。"
        let tokens = tok.tokenize(input)
        let rebuilt = tokens.map { $0.surface }.joined()
        XCTAssertEqual(rebuilt, Normalize.nfkc(input),
                       "concatenated surfaces must equal the NFKC input for clean char→token mapping")
    }

    func testWhitespaceAndParagraphsPreserved() throws {
        let tok = try makeTokenizer()
        let input = "吾輩は猫である。\n\n　名前はまだ無い。 Hello world."
        let tokens = tok.tokenize(input)
        let rebuilt = tokens.map { $0.surface }.joined()
        XCTAssertEqual(rebuilt, Normalize.nfkc(input),
                       "whitespace/newlines must survive tokenization (lossless surfaces)")
        XCTAssertTrue(rebuilt.contains("\n\n"), "paragraph break must be preserved")
    }

    func testMeCabIntoMapperCleanAlignment() throws {
        let tok = try makeTokenizer()
        let input = "私は本を読みます"
        let tokens = tok.tokenize(input)
        let alignment = uniform(Normalize.nfkc(input))

        let spans = CharTokenMapper.map(tokens: tokens, alignment: alignment)

        XCTAssertEqual(spans.count, tokens.count)
        XCTAssertTrue(spans.allSatisfy { $0.matchedChars == $0.surface.count },
                      "clean alignment should match every char; got \(spans.map { ($0.surface, $0.matchedChars) })")
        for k in 1..<spans.count {
            XCTAssertEqual(spans[k].start, spans[k - 1].end, accuracy: 1e-9,
                           "tokens should tile the timeline with no gaps on a 1:1 alignment")
        }
    }
}
