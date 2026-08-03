import XCTest
@testable import ReaderCore

final class KanaRepairTests: XCTestCase {
    func testDetectsAFlattenedSource() {
        let readings = ["じようぜつ", "みようじ", "ししゆう", "ちゆうちよ", "ほうりゆうじ",
                        "きちようめん", "びようどういん", "しゆういち", "そしやく", "しやく",
                        "ひようひよう", "らくしゆう", "きやしや"]
        XCTAssertTrue(KanaRepair.looksFlattened(readings))
    }

    func testASingleSmallKanaRulesOutFlattening() {
        var readings = Array(repeating: "じようぜつ", count: 20)
        readings.append("しょう")
        XCTAssertFalse(KanaRepair.looksFlattened(readings))
    }

    func testPlainReadingsAreNotMistakenForFlattened() {
        let readings = ["のぞみ", "おうまえ", "よろいづか", "くみこ", "れいな", "なつき",
                        "はづき", "きたうじ", "みどり", "たき", "かおり", "りこ", "ゆうこ"]
        XCTAssertFalse(KanaRepair.looksFlattened(readings))
    }

    func testTooFewReadingsIsNotEnoughEvidence() {
        XCTAssertFalse(KanaRepair.looksFlattened(["じようぜつ", "みようじ"]))
    }

    func testRestoresYoon() {
        XCTAssertEqual(KanaRepair.restoreSmallKana("じようぜつ"), "じょうぜつ")
        XCTAssertEqual(KanaRepair.restoreSmallKana("みようじ"), "みょうじ")
        XCTAssertEqual(KanaRepair.restoreSmallKana("ちゆうちよ"), "ちゅうちょ")
        XCTAssertEqual(KanaRepair.restoreSmallKana("しゆういち"), "しゅういち")
        XCTAssertEqual(KanaRepair.restoreSmallKana("きやしや"), "きゃしゃ")
    }

    func testRestoresKatakanaDigraphs() {
        XCTAssertEqual(KanaRepair.restoreSmallKana("サフアイア"), "サファイア")
        XCTAssertEqual(KanaRepair.restoreSmallKana("ヴアイオリン"), "ヴァイオリン")
    }

    func testDoesNotGuessGemination() {
        XCTAssertEqual(KanaRepair.restoreSmallKana("まつり"), "まつり")
        XCTAssertEqual(KanaRepair.restoreSmallKana("がつこう"), "がつこう")
    }

    func testLeavesOrdinaryReadingsAlone() {
        for r in ["のぞみ", "おうまえ", "よろいづか", "くみこ", "きたうじ", "サクソフォン"] {
            XCTAssertEqual(KanaRepair.restoreSmallKana(r), r, r)
        }
    }

    func testOnlyIRowKanaTriggerYoon() {
        XCTAssertEqual(KanaRepair.restoreSmallKana("おおや"), "おおや")
        XCTAssertEqual(KanaRepair.restoreSmallKana("つゆ"), "つゆ")
        XCTAssertEqual(KanaRepair.restoreSmallKana("はやし"), "はやし")
    }

    func testFlattenedIgnoresSmallKanaDifferencesOnly() {
        XCTAssertEqual(KanaRepair.flattened("じょうぜつ"), KanaRepair.flattened("じようぜつ"))
        XCTAssertNotEqual(KanaRepair.flattened("しょう"), KanaRepair.flattened("しよ"))
        XCTAssertEqual(KanaRepair.flattened("がっこう"), "がつこう")
    }

    func testTokenizerWinsWhenTheReadingsAreTheSameWord() {
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "じようぜつ", tokenizer: "じょうぜつ"),
                       "じょうぜつ")
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "しょう", tokenizer: "しよう"), "しよう")
    }

    func testBookWinsWhenTheReadingsAreDifferentWords() {
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "おうまえ", tokenizer: "きぜん"), "おうまえ")
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "のぞみ", tokenizer: "きみ"), "のぞみ")
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "おうまえ", tokenizer: nil), "おうまえ")
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "おうまえ", tokenizer: ""), "おうまえ")
    }
}
