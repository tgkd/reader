import XCTest
@testable import ReaderCore

final class PronunciationLexiconTests: XCTestCase {

    private func reading(_ start: Int, _ surface: String, _ reading: String) -> SourceReading {
        SourceReading(start: start, length: surface.count, surface: surface, reading: reading)
    }

    func testAdmitsAnAnnotatedMultiCharacterName() {
        let text = "黄前久美子です。"
        let lex = PronunciationLexicon.build(
            text: text, readings: [reading(0, "黄前", "おうまえ")])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "黄前", reading: "おうまえ")])
        XCTAssertTrue(lex.rejected.isEmpty)
    }

    func testAdmitsASemanticGloss() {
        let text = "緑輝はコントラバスを弾く。"
        let lex = PronunciationLexicon.build(
            text: text, readings: [reading(0, "緑輝", "サファイア")])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "緑輝", reading: "サファイア")])
    }

    func testAdmitsASurfaceAnnotatedAtEveryOccurrence() {
        let text = "黄前さんと黄前さん。"
        let lex = PronunciationLexicon.build(text: text, readings: [
            reading(0, "黄前", "おうまえ"),
            reading(5, "黄前", "おうまえ"),
        ])

        XCTAssertEqual(lex.rules.count, 1)
        XCTAssertEqual(lex.rejected, [])
    }

    func testRefusesSingleCharacterBase() {
        let lex = PronunciationLexicon.build(
            text: "長い部長。", readings: [reading(3, "長", "ちょう")])

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first?.rejection, .singleCharacterBase)
    }

    func testRefusesSurfaceTheBookReadsTwoWays() {
        let text = "明日と明日。"
        let lex = PronunciationLexicon.build(text: text, readings: [
            reading(0, "明日", "あした"),
            reading(3, "明日", "あす"),
        ])

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first?.rejection, .ambiguousInBook(["あした", "あす"]))
    }

    func testRefusesNonKanaReading() {
        let lex = PronunciationLexicon.build(
            text: "黄前です。", readings: [reading(0, "黄前", "Oumae")])

        XCTAssertEqual(lex.rejected.first?.rejection, .readingNotKana)
    }

    func testRefusesRuleThatChangesNothing() {
        let lex = PronunciationLexicon.build(
            text: "さくらが咲く。", readings: [reading(0, "さくら", "さくら")])

        XCTAssertEqual(lex.rejected.first?.rejection, .readingMatchesSurface)
    }

    func testRefusesSurfaceOccurringWhereTheBookDidNotAnnotateIt() {
        let text = "希美さん。希美子さん。"
        let lex = PronunciationLexicon.build(
            text: text, readings: [reading(0, "希美", "のぞみ")])

        XCTAssertTrue(lex.rules.isEmpty, "希美 also sits inside 希美子, which was never annotated")
        guard case .unannotatedOccurrence(let n)? = lex.rejected.first?.rejection else {
            return XCTFail("expected an unannotated-occurrence rejection, got \(String(describing: lex.rejected.first?.rejection))")
        }
        XCTAssertEqual(n, 1)
    }

    func testRefusesSurfaceThatSitsInsideALongerReading() {
        let text = "手紙と紙。"
        let lex = PronunciationLexicon.build(text: text, readings: [
            reading(0, "手紙", "てがみ"),
            reading(3, "紙", "かみ"),
        ])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "手紙", reading: "てがみ")],
                       "the longer, unambiguous span survives")
        XCTAssertTrue(lex.rejected.contains { $0.surface == "紙" })
    }

    private func repaired(_ start: Int, _ surface: String,
                          raw: String, restored: String) -> SourceReading {
        SourceReading(start: start, length: surface.count, surface: surface,
                      reading: restored, rawReading: raw)
    }

    func testRefusesRepairedReadingWithoutCorroboration() {
        let lex = PronunciationLexicon.build(
            text: "饒舌な人。",
            readings: [repaired(0, "饒舌", raw: "じようぜつ", restored: "じょうぜつ")],
            isFlattened: true)

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first?.rejection, .unconfirmedRepair)
    }

    func testAcceptsRepairedReadingWhenTheTokenizerAgrees() {
        let lex = PronunciationLexicon.build(
            text: "饒舌な人。",
            readings: [repaired(0, "饒舌", raw: "じようぜつ", restored: "じょうぜつ")],
            isFlattened: true,
            corroborate: { $0 == "饒舌" ? "じょうぜつ" : nil })

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "饒舌", reading: "じょうぜつ")],
                       "comparison happens in the flattened space; the tokenizer's spelling wins")
    }

    func testAdmitsUntouchedReadingsFromAFlattenedBookWithoutCorroboration() {
        let lex = PronunciationLexicon.build(
            text: "黄前久美子です。",
            readings: [reading(0, "黄前", "おうまえ")],
            isFlattened: true,
            corroborate: { _ in nil })

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "黄前", reading: "おうまえ")])
        XCTAssertTrue(lex.rejected.isEmpty)
    }

    func testFlattenedBookLosesRepairedNamesTheTokenizerCannotConfirm() {
        let lex = PronunciationLexicon.build(
            text: "明静工科高校。",
            readings: [repaired(0, "明静工科",
                                raw: "みようじようこうか", restored: "みょうじょうこうか")],
            isFlattened: true,
            corroborate: { _ in nil })

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first?.rejection, .unconfirmedRepair)
    }

    func testEmitsNFKCNormalizedRules() {
        let text = "ﾎﾞｰﾙを持つ。"
        let lex = PronunciationLexicon.build(
            text: text, readings: [reading(0, "ﾎﾞｰﾙ", "ぼーる")])

        XCTAssertEqual(lex.rules.first?.surface, "ボール",
                       "half-width source must be asserted in the form TTS will see")
    }

    func testEmptyInputProducesEmptyLexicon() {
        let lex = PronunciationLexicon.build(text: "本文。", readings: [])
        XCTAssertEqual(lex, Lexicon(rules: [], rejected: []))
    }
}
