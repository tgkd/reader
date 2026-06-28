import XCTest
@testable import ReaderCore

/// Exercises the real MeCab+IPADic tokenizer and the MeCab → mapper pipeline.
/// These need the bundled IPADic resource; they run under `swift test` on macOS.
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

    // MARK: - Basic tokenization + readings

    func testTokenizesAndProducesReadings() throws {
        let tok = try makeTokenizer()
        let tokens = tok.tokenize("今日は良い天気ですね")

        XCTAssertGreaterThan(tokens.count, 1, "should split into multiple tokens")
        // At least the kanji-bearing tokens should carry a kana reading.
        let withReadings = tokens.filter { $0.reading != nil }
        XCTAssertFalse(withReadings.isEmpty, "expected kana readings from IPADic")
        // 天気 should read てんき.
        if let tenki = tokens.first(where: { $0.surface == "天気" }) {
            XCTAssertEqual(tenki.reading, "てんき")
        } else {
            XCTFail("expected a 天気 token; got \(tokens.map { $0.surface })")
        }
    }

    // MARK: - Dictionary form (kanji lemma) for tap-to-define

    func testDictionaryFormGivesKanjiLemmaAndHiraganaReading() throws {
        let tok = try makeTokenizer()
        let tokens = tok.tokenize("どこで生まれたか")
        // The inflected verb must expose its KANJI dictionary form (生まれる), not a
        // hiragana-ized reading — this is the key tap-to-define keys on.
        let lemma = tokens.first { $0.dictionaryForm == "生まれる" }
        XCTAssertNotNil(lemma,
            "expected a 生まれる lemma; got \(tokens.map { ($0.surface, $0.dictionaryForm ?? "·") })")
        // Readings must stay hiragana for furigana — no katakana should leak through.
        let leakedKatakana = tokens.contains {
            ($0.reading ?? "").unicodeScalars.contains { (0x30A1...0x30F6).contains($0.value) }
        }
        XCTAssertFalse(leakedKatakana, "readings must be hiragana, got \(tokens.map { $0.reading ?? "·" })")
    }

    // MARK: - Surfaces reconstruct the (normalized) input

    func testSurfacesReconstructInput() throws {
        let tok = try makeTokenizer()
        let input = "吾輩は猫である。名前はまだ無い。"
        let tokens = tok.tokenize(input)
        let rebuilt = tokens.map { $0.surface }.joined()
        XCTAssertEqual(rebuilt, Normalize.nfkc(input),
                       "concatenated surfaces must equal the NFKC input for clean char→token mapping")
    }

    // MARK: - End-to-end: MeCab tokens → mapper over a 1:1 char alignment

    func testMeCabIntoMapperCleanAlignment() throws {
        let tok = try makeTokenizer()
        let input = "私は本を読みます"
        let tokens = tok.tokenize(input)
        let alignment = uniform(Normalize.nfkc(input))   // perfect 1:1 char timings

        let spans = CharTokenMapper.map(tokens: tokens, alignment: alignment)

        XCTAssertEqual(spans.count, tokens.count)
        // Every token should have matched its characters 1:1 against a clean alignment.
        XCTAssertTrue(spans.allSatisfy { $0.matchedChars == $0.surface.count },
                      "clean alignment should match every char; got \(spans.map { ($0.surface, $0.matchedChars) })")
        // Monotonic and contiguous: each token starts where the previous ended.
        for k in 1..<spans.count {
            XCTAssertEqual(spans[k].start, spans[k - 1].end, accuracy: 1e-9,
                           "tokens should tile the timeline with no gaps on a 1:1 alignment")
        }
    }
}
