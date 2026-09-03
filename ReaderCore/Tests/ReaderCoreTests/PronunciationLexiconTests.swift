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

    func testRefusesSurfaceLeftBareInAnotherChapter() {
        let annotated = Chapter(text: "希美さん。",
                                sourceReadings: [reading(0, "希美", "のぞみ")])
        let bare = Chapter(text: "希美子さんも来た。")

        XCTAssertEqual(PronunciationLexicon.build(chapters: [annotated]).rules.count, 1,
                       "on its own chapter the name looks safe")
        XCTAssertTrue(PronunciationLexicon.build(chapters: [annotated, bare]).rules.isEmpty,
                      "希美 sits unvouched inside 希美子 one chapter later")
    }

    func testCountsOccurrencesAcrossEveryChapter() {
        let one = Chapter(text: "黄前さん。", sourceReadings: [reading(0, "黄前", "おうまえ")])
        let two = Chapter(text: "また黄前さん。", sourceReadings: [reading(2, "黄前", "おうまえ")])
        let lex = PronunciationLexicon.build(chapters: [one, two])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "黄前", reading: "おうまえ")])
        XCTAssertTrue(lex.rejected.isEmpty)
    }

    func testAmbiguityIsJudgedOverTheWholeBookNotOneChapter() {
        let one = Chapter(text: "明日ね。", sourceReadings: [reading(0, "明日", "あした")])
        let two = Chapter(text: "明日は雨。", sourceReadings: [reading(0, "明日", "あす")])

        XCTAssertTrue(PronunciationLexicon.build(chapters: [one, two]).rules.isEmpty)
        XCTAssertEqual(PronunciationLexicon.build(chapters: [one, two]).rejected.first?.rejection,
                       .ambiguousInBook(["あした", "あす"]))
    }

    func testOneFlattenedChapterMakesTheWholeBookFlattened() {
        let clean = Chapter(text: "黄前さん。", sourceReadings: [reading(0, "黄前", "おうまえ")])
        let broken = Chapter(text: "饒舌な人。",
                             sourceReadings: [repaired(0, "饒舌",
                                                       raw: "じようぜつ", restored: "じょうぜつ")],
                             isFlattenedSource: true)
        let lex = PronunciationLexicon.build(chapters: [clean, broken])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "黄前", reading: "おうまえ")],
                       "the untouched name survives")
        XCTAssertEqual(lex.rejected.first?.rejection, .unconfirmedRepair,
                       "the repaired one needs corroboration even though its chapter carried the flag")
    }

    private func pair(_ start: Int, _ surface: String, _ reading: String,
                      group: Int) -> SourceReading {
        SourceReading(start: start, length: surface.count, surface: surface,
                      reading: reading, groupLength: group)
    }

    func testReassemblesAMonorubyNameIntoOneRule() {
        let lex = PronunciationLexicon.build(text: "久美子です。", readings: [
            pair(0, "久", "く", group: 3),
            pair(1, "美", "み", group: 3),
            pair(2, "子", "こ", group: 3),
        ])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "久美子", reading: "くみこ")])
        XCTAssertTrue(lex.rejected.isEmpty)
    }

    func testUngroupedSingleCharactersStayRefused() {
        let lex = PronunciationLexicon.build(text: "久美子です。", readings: [
            reading(0, "久", "く"),
            reading(1, "美", "み"),
            reading(2, "子", "こ"),
        ])

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.count, 3)
    }

    func testAGroupTruncatedByAChapterSplitIsNotAssembled() {
        let lex = PronunciationLexicon.build(text: "子です。", readings: [
            pair(0, "子", "こ", group: 3),
        ])

        XCTAssertTrue(lex.rules.isEmpty, "a group missing its head must not become a rule")
        XCTAssertEqual(lex.rejected.first?.rejection, .singleCharacterBase)
    }

    func testAssembledGroupInheritsRepairFromAnyPart() {
        let lex = PronunciationLexicon.build(
            text: "緑輝です。",
            readings: [
                SourceReading(start: 0, length: 1, surface: "緑", reading: "サファ",
                              rawReading: "サフア", groupLength: 2),
                pair(1, "輝", "イア", group: 2),
            ],
            isFlattened: true,
            corroborate: { _ in nil })

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first?.rejection, .unconfirmedRepair,
                       "one repaired part taints the whole assembled name")
    }

    func testARepairedReadingSeenThroughATokenStillNeedsCorroboration() {
        let readings = [
            SourceReading(start: 0, length: 1, surface: "匂", reading: "におう", groupLength: 2),
            SourceReading(start: 1, length: 1, surface: "宮", reading: "みゃ",
                          rawReading: "みや", groupLength: 2),
        ]
        let blind = PronunciationLexicon.build(
            text: "匂宮だ。", readings: readings, isFlattened: true,
            tokens: [Token(surface: "匂"), Token(surface: "宮"), Token(surface: "だ"),
                     Token(surface: "。")],
            corroborate: { _ in nil })

        XCTAssertTrue(blind.rules.isEmpty, "\(blind.rules)")
        XCTAssertEqual(blind.rejected.first(where: { $0.surface == "宮だ" })?.rejection,
                       .unconfirmedRepair,
                       "the window descends from a repaired annotation, so the gate that judges "
                           + "the annotation must judge the window too; keying it on the "
                           + "surface let みゃだ ship for a word the book prints みや")

        let confirmed = PronunciationLexicon.build(
            text: "匂宮だ。", readings: readings, isFlattened: true,
            tokens: [Token(surface: "匂", reading: "におう"), Token(surface: "宮", reading: "みや"),
                     Token(surface: "だ", reading: "だ"), Token(surface: "。")],
            corroborate: { _ in nil })

        XCTAssertEqual(confirmed.rules, [PronunciationRule(surface: "宮だ", reading: "みやだ"),
                                         PronunciationRule(surface: "匂宮", reading: "におうみや")],
                       "the chapter's own tokens carry the tokenizer's reading of each window, "
                           + "and its spelling wins over the repair")
    }

    func testTheTokenizersOwnReadingCorroboratesARepairedGroup() {
        let readings = [
            SourceReading(start: 0, length: 1, surface: "寂", reading: "せき", groupLength: 2),
            SourceReading(start: 1, length: 1, surface: "寥", reading: "りょう",
                          rawReading: "りよう", groupLength: 2),
        ]
        let lex = PronunciationLexicon.build(
            text: "寂寥とした。", readings: readings, isFlattened: true,
            tokens: [Token(surface: "寂寥", reading: "せきりょう"), Token(surface: "と"),
                     Token(surface: "し"), Token(surface: "た"), Token(surface: "。")],
            corroborate: { _ in nil })

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "寂寥", reading: "せきりょう")],
                       "the isolated lookup asks about the parts the book annotated, never the "
                           + "word; the token that spans the group already knows it")
    }

    func testARepairTheTokenizerReadsDifferentlyStaysRefused() {
        let readings = [
            SourceReading(start: 0, length: 1, surface: "明", reading: "みょう",
                          rawReading: "みよう", groupLength: 2),
            SourceReading(start: 1, length: 1, surface: "静", reading: "じょう",
                          rawReading: "じよう", groupLength: 2),
        ]
        let lex = PronunciationLexicon.build(
            text: "明静高校。", readings: readings, isFlattened: true,
            tokens: [Token(surface: "明", reading: "あきら"), Token(surface: "静", reading: "せい"),
                     Token(surface: "高校", reading: "こうこう"), Token(surface: "。")],
            corroborate: { _ in nil })

        XCTAssertTrue(lex.rules.isEmpty, "\(lex.rules)")
        XCTAssertEqual(lex.rejected.first(where: { $0.surface == "明静" })?.rejection,
                       .unconfirmedRepair)
    }

    func testAdmitsAStemAnnotationReadAgainstItsToken() {
        let lex = PronunciationLexicon.build(
            text: "響け！",
            readings: [reading(0, "響", "ひび")],
            tokens: [Token(surface: "響け"), Token(surface: "！")])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "響け", reading: "ひびけ")],
                       "alone, 響 is a single-character base and narration is told nothing at all "
                           + "about a reading the book printed")
    }

    func testTheBareAnnotationStaysRefusedAlongsideTheComposedRule() {
        let lex = PronunciationLexicon.build(
            text: "響け！",
            readings: [reading(0, "響", "ひび")],
            tokens: [Token(surface: "響け"), Token(surface: "！")])

        XCTAssertEqual(lex.rejected.first(where: { $0.surface == "響" })?.rejection,
                       .singleCharacterBase,
                       "the one-character alias would still match 響 inside other words")
    }

    func testAStandaloneKanjiTokenGetsAContextualBase() {
        let lex = PronunciationLexicon.build(
            text: "この糸は己のものだ。",
            readings: [reading(4, "己", "おれ")],
            tokens: [Token(surface: "この"), Token(surface: "糸"), Token(surface: "は"),
                     Token(surface: "己"), Token(surface: "の"), Token(surface: "もの"),
                     Token(surface: "だ"), Token(surface: "。")])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "己の", reading: "おれの")],
                       "the token IS the kanji, so promotion to it yields nothing; the base has to "
                           + "widen past the token before it can be sent at all")
    }

    func testTheContextualBaseIsTheShortestOneThatWorks() {
        let lex = PronunciationLexicon.build(
            text: "静かな家に住む。",
            readings: [reading(3, "家", "うち")],
            tokens: [Token(surface: "静か"), Token(surface: "な"), Token(surface: "家"),
                     Token(surface: "に"), Token(surface: "住む"), Token(surface: "。")])

        XCTAssertEqual(lex.rules.map(\.surface), ["家に"],
                       "widening stops as soon as the base is sendable, and a tie goes to the "
                           + "window headed by the token the book actually vouched for")
    }

    func testAContextualBaseCarriesABoundReading() {
        let lex = PronunciationLexicon.build(
            text: "詩人面をしたい。",
            readings: [reading(2, "面", "づら")],
            tokens: [Token(surface: "詩人"), Token(surface: "面"), Token(surface: "を"),
                     Token(surface: "し"), Token(surface: "たい"), Token(surface: "。")])

        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "面を", reading: "づらを")],
                       "づら exists only bound; the phrase is the smallest thing that can carry it")
    }

    func testAContextualBaseStillNeedsEveryOccurrenceAnnotated() {
        let lex = PronunciationLexicon.build(
            text: "己のものだ。己のものだ。",
            readings: [reading(0, "己", "おれ")],
            tokens: [Token(surface: "己"), Token(surface: "の"), Token(surface: "もの"),
                     Token(surface: "だ"), Token(surface: "。"),
                     Token(surface: "己"), Token(surface: "の"), Token(surface: "もの"),
                     Token(surface: "だ"), Token(surface: "。")])

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first(where: { $0.surface == "己の" })?.rejection,
                       .unannotatedOccurrence(count: 1),
                       "a rule replaces every literal match, so the book must vouch for every one")
    }

    func testAContextualBaseIsNotBuiltWhereTheBookSaidNothing() {
        let lex = PronunciationLexicon.build(
            text: "この糸は己のものだ。",
            readings: [],
            tokens: [Token(surface: "この"), Token(surface: "糸"), Token(surface: "は"),
                     Token(surface: "己"), Token(surface: "の"), Token(surface: "もの"),
                     Token(surface: "だ"), Token(surface: "。")])

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertTrue(lex.rejected.isEmpty)
    }

    func testAComposedRuleStillNeedsEveryOccurrenceAnnotated() {
        let lex = PronunciationLexicon.build(
            text: "響け。響け。",
            readings: [reading(0, "響", "ひび")],
            tokens: [Token(surface: "響け"), Token(surface: "。"),
                     Token(surface: "響け"), Token(surface: "。")])

        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first(where: { $0.surface == "響け" })?.rejection,
                       .unannotatedOccurrence(count: 1),
                       "composing a token reading must not buy a pass on the occurrence gate")
    }

    func testWithoutTokensTheBareAnnotationIsAllThereIs() {
        let lex = PronunciationLexicon.build(text: "響け！", readings: [reading(0, "響", "ひび")])

        XCTAssertTrue(lex.rules.isEmpty, "the segmentation is what turns 響 into 響け")
    }
}
