import XCTest
@testable import ReaderCore

final class NormalizeTests: XCTestCase {
    func testDictionaryKanaFold() {
        for input in ["ひどい", "ヒドイ", "ヒドい", "ﾋﾄﾞｲ"] {
            XCTAssertEqual(Normalize.kanaFold(input), "ひどい")
        }
        XCTAssertEqual(Normalize.kanaFold("ｺｰﾋｰ"), "こーひー")
        XCTAssertEqual(Normalize.kanaFold("カ\u{3099}"), "が")
    }

    func testKanaFoldDoesNotGuessPronunciationOrInflection() {
        XCTAssertEqual(Normalize.kanaFold("衝く"), "衝く")
        XCTAssertEqual(Normalize.kanaFold("ひどかった"), "ひどかった")
        XCTAssertEqual(Normalize.kanaFold("コー"), "こー")
    }
}
