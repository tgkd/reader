import XCTest
@testable import ReaderCore

final class CharTokenMapperTests: XCTestCase {
    private func uniform(_ chars: [String], dt: Double = 0.1) -> Alignment {
        var starts: [Double] = []
        var ends: [Double] = []
        for k in 0..<chars.count {
            starts.append(Double(k) * dt)
            ends.append(Double(k + 1) * dt)
        }
        return Alignment(characters: chars, startTimes: starts, endTimes: ends)
    }

    private func chars(_ s: String) -> [String] { s.map { String($0) } }

    private func assertMonotonic(_ spans: [TokenSpan], file: StaticString = #filePath, line: UInt = #line) {
        for k in 1..<spans.count {
            XCTAssertGreaterThanOrEqual(spans[k].start, spans[k - 1].start,
                                        "start regressed at \(k)", file: file, line: line)
        }
        for s in spans {
            XCTAssertGreaterThanOrEqual(s.end, s.start, "end < start", file: file, line: line)
        }
    }

    func testCleanMapping() {
        let tokens = [Token(surface: "食べ", reading: "たべ"), Token(surface: "ます", reading: "ます")]
        let alignment = uniform(chars("食べます"))
        let spans = CharTokenMapper.map(tokens: tokens, alignment: alignment)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].start, 0.0, accuracy: 1e-9)
        XCTAssertEqual(spans[0].end, 0.2, accuracy: 1e-9)
        XCTAssertEqual(spans[1].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(spans[1].end, 0.4, accuracy: 1e-9)
        XCTAssertEqual(spans.map { $0.matchedChars }, [2, 2])
        assertMonotonic(spans)
    }

    func testPunctuationAttachedToOwnToken() {
        let tokens = [Token(surface: "今日"), Token(surface: "、"), Token(surface: "晴れ")]
        let alignment = uniform(chars("今日、晴れ"))
        let spans = CharTokenMapper.map(tokens: tokens, alignment: alignment)

        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[1].surface, "、")
        XCTAssertEqual(spans[1].start, 0.2, accuracy: 1e-9)
        XCTAssertEqual(spans[1].end, 0.3, accuracy: 1e-9)
        XCTAssertEqual(spans[2].start, 0.3, accuracy: 1e-9)
        assertMonotonic(spans)
    }

    func testAlignmentHasExtraWhitespace() {
        let tokens = [Token(surface: "週末"), Token(surface: "は")]
        let alignment = uniform(["週", "末", " ", "は"])
        let spans = CharTokenMapper.map(tokens: tokens, alignment: alignment)

        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].end, 0.2, accuracy: 1e-9)
        XCTAssertEqual(spans[1].start, 0.3, accuracy: 1e-9)
        XCTAssertEqual(spans[1].end, 0.4, accuracy: 1e-9)
        assertMonotonic(spans)
    }

    func testTokensHaveCharDroppedByAPI() {
        let tokens = [Token(surface: "A"), Token(surface: "B"), Token(surface: "C")]
        let alignment = uniform(["A", "C"])
        let spans = CharTokenMapper.map(tokens: tokens, alignment: alignment)

        XCTAssertEqual(spans.count, 3)
        XCTAssertEqual(spans[0].matchedChars, 1)
        XCTAssertEqual(spans[1].matchedChars, 0, "B should be unmatched")
        XCTAssertEqual(spans[2].matchedChars, 1)
        XCTAssertEqual(spans[1].start, 0.1, accuracy: 1e-9)
        assertMonotonic(spans)
    }

    func testSurrogatePairKanji() {
        let tokens = [Token(surface: "𠮷野")]
        let alignment = uniform(["𠮷", "野"])
        let spans = CharTokenMapper.map(tokens: tokens, alignment: alignment)

        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].matchedChars, 2)
        XCTAssertEqual(spans[0].start, 0.0, accuracy: 1e-9)
        XCTAssertEqual(spans[0].end, 0.2, accuracy: 1e-9)
        assertMonotonic(spans)
    }

    func testMonotonicClamp() {
        let tokens = [Token(surface: "あ"), Token(surface: "い"), Token(surface: "う")]
        let alignment = Alignment(characters: ["あ", "い", "う"],
                                  startTimes: [0.0, 0.0, 0.5],
                                  endTimes: [0.4, 0.1, 0.6])
        let spans = CharTokenMapper.map(tokens: tokens, alignment: alignment)

        assertMonotonic(spans)
        XCTAssertGreaterThanOrEqual(spans[1].start, spans[0].start)
        XCTAssertEqual(spans[2].start, 0.5, accuracy: 1e-9)
    }

    func testNFKCNormalizationFoldsZenkaku() {
        XCTAssertEqual(Normalize.nfkc("１２３"), "123")
        XCTAssertEqual(Normalize.nfkc("ＡＢＣ"), "ABC")
        XCTAssertEqual(Normalize.nfkc("ｶﾀｶﾅ"), "カタカナ")
    }

    func testEmptyTokens() {
        XCTAssertTrue(CharTokenMapper.map(tokens: [], alignment: uniform(["あ"])).isEmpty)
    }
}
