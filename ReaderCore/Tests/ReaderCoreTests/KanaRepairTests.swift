import XCTest
@testable import ReaderCore

/// Some EPUBs arrive with every 小書き kana upcased. The reading is asserted with the
/// book's authority — it overrides the tokenizer, drives the furigana, and would be
/// spoken — so a flattened one is worse than no ruby at all.
final class KanaRepairTests: XCTestCase {

    // MARK: - Detection

    /// The real signal, from 響け！ユーфォニアム 2: dozens of readings, not one small
    /// kana among them, and 拗音-shaped sequences throughout.
    func testDetectsAFlattenedSource() {
        let readings = ["じようぜつ", "みようじ", "ししゆう", "ちゆうちよ", "ほうりゆうじ",
                        "きちようめん", "びようどういん", "しゆういち", "そしやく", "しやく",
                        "ひようひよう", "らくしゆう", "きやしや"]
        XCTAssertTrue(KanaRepair.looksFlattened(readings))
    }

    /// One small kana anywhere is proof the source could write them.
    func testASingleSmallKanaRulesOutFlattening() {
        var readings = Array(repeating: "じようぜつ", count: 20)
        readings.append("しょう")
        XCTAssertFalse(KanaRepair.looksFlattened(readings))
    }

    /// A book whose readings simply have no 拗音 must not be "repaired".
    func testPlainReadingsAreNotMistakenForFlattened() {
        let readings = ["のぞみ", "おうまえ", "よろいづか", "くみこ", "れいな", "なつき",
                        "はづき", "きたうじ", "みどり", "たき", "かおり", "りこ", "ゆうこ"]
        XCTAssertFalse(KanaRepair.looksFlattened(readings))
    }

    /// Too small a sample cannot support the conclusion.
    func testTooFewReadingsIsNotEnoughEvidence() {
        XCTAssertFalse(KanaRepair.looksFlattened(["じようぜつ", "みようじ"]))
    }

    // MARK: - Restoration

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

    /// Gemination is deliberately NOT restored: つ before a consonant is ambiguous
    /// (まつり is a word), and a wrong 促音 carries the book's authority.
    func testDoesNotGuessGemination() {
        XCTAssertEqual(KanaRepair.restoreSmallKana("まつり"), "まつり")
        XCTAssertEqual(KanaRepair.restoreSmallKana("がつこう"), "がつこう")
    }

    /// A reading that is already correct must pass through untouched — the restoration
    /// runs over every reading in a flattened book, including ones with no 拗音.
    func testLeavesOrdinaryReadingsAlone() {
        for r in ["のぞみ", "おうまえ", "よろいづか", "くみこ", "きたうじ", "サクソフォン"] {
            XCTAssertEqual(KanaRepair.restoreSmallKana(r), r, r)
        }
    }

    /// や/ゆ/よ after a kana that cannot carry 拗音 is a real mora.
    func testOnlyIRowKanaTriggerYoon() {
        XCTAssertEqual(KanaRepair.restoreSmallKana("おおや"), "おおや")
        XCTAssertEqual(KanaRepair.restoreSmallKana("つゆ"), "つゆ")
        XCTAssertEqual(KanaRepair.restoreSmallKana("はやし"), "はやし")
    }

    // MARK: - Flattening as a comparison space

    func testFlattenedIgnoresSmallKanaDifferencesOnly() {
        XCTAssertEqual(KanaRepair.flattened("じょうぜつ"), KanaRepair.flattened("じようぜつ"))
        XCTAssertNotEqual(KanaRepair.flattened("しょう"), KanaRepair.flattened("しよ"))
        XCTAssertEqual(KanaRepair.flattened("がっこう"), "がつこう")
    }

    // MARK: - The tokenizer as the backstop

    /// THE property that makes restoring safe. Restoration is a judgement — しよう is
    /// しょう for 少 but しよう for 使用 — and this comparison silently corrects a wrong
    /// call in EITHER direction on any word the tokenizer knows, because it compares in
    /// the space where both spellings look the same.
    func testTokenizerWinsWhenTheReadingsAreTheSameWord() {
        // Flattened book vs correct tokenizer: the tokenizer's spelling wins.
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "じようぜつ", tokenizer: "じょうぜつ"),
                       "じょうぜつ")
        // Over-eager restoration vs a tokenizer that is right: still corrected.
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "しょう", tokenizer: "しよう"), "しよう")
    }

    /// But a reading that differs as a WORD is exactly what the ruby was read for, and
    /// must survive — 黄前 is おうまえ however confidently MeCab says きぜん.
    func testBookWinsWhenTheReadingsAreDifferentWords() {
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "おうまえ", tokenizer: "きぜん"), "おうまえ")
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "のぞみ", tokenizer: "きみ"), "のぞみ")
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "おうまえ", tokenizer: nil), "おうまえ")
        XCTAssertEqual(SourceReadingOverlay.preferred(book: "おうまえ", tokenizer: ""), "おうまえ")
    }
}
