import XCTest
@testable import ReaderCore

final class SourceReadingTests: XCTestCase {
    func testDecodesAChapterWrittenBeforeSourceReadingsExisted() throws {
        let legacy = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","title":"一","text":"吾輩は猫である。"}
        """
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(legacy.utf8))
        XCTAssertEqual(chapter.text, "吾輩は猫である。")
        XCTAssertEqual(chapter.title, "一")
        XCTAssertEqual(chapter.sourceReadings, [])
    }

    func testDecodesALegacyLibraryDocument() throws {
        let legacy = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","title":"本",
          "chapters":[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","text":"あ"}],
          "progress":{"chapterIndex":0,"time":0,"fraction":0}}]
        """
        let docs = try JSONDecoder().decode([Document].self, from: Data(legacy.utf8))
        XCTAssertEqual(docs.first?.chapters.first?.text, "あ")
    }

    func testMalformedAnnotationsDoNotCostTheChapterText() throws {
        let broken = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","text":"あ","sourceReadings":"nonsense"}
        """
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(broken.utf8))
        XCTAssertEqual(chapter.text, "あ")
        XCTAssertEqual(chapter.sourceReadings, [])
    }

    func testOmitsTheKeyWhenThereAreNoReadings() throws {
        let data = try JSONEncoder().encode(Chapter(text: "あ"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sourceReadings"))
    }

    func testDecodesAChapterWrittenBeforeTheFlattenedFlagExisted() throws {
        let legacy = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","text":"あ",
         "sourceReadings":[{"start":0,"length":1,"surface":"あ","reading":"あ"}]}
        """
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(legacy.utf8))
        XCTAssertEqual(chapter.text, "あ")
        XCTAssertFalse(chapter.isFlattenedSource, "absent means the file was never repaired")
        XCTAssertNil(chapter.sourceReadings.first?.rawReading)
        XCTAssertFalse(chapter.sourceReadings.first!.wasRepaired)
    }

    func testOmitsTheFlattenedFlagWhenFalse() throws {
        let data = try JSONEncoder().encode(Chapter(text: "あ"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("isFlattenedSource"))
    }

    func testRoundTripsTheFlattenedFlagAndRawReading() throws {
        let c = Chapter(text: "饒舌",
                        sourceReadings: [SourceReading(start: 0, length: 2, surface: "饒舌",
                                                       reading: "じょうぜつ",
                                                       rawReading: "じようぜつ")],
                        isFlattenedSource: true)
        let back = try JSONDecoder().decode(Chapter.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.isFlattenedSource)
        XCTAssertEqual(back.sourceReadings.first?.rawReading, "じようぜつ")
        XCTAssertTrue(back.sourceReadings.first!.wasRepaired)
    }

    func testSplittingCarriesProvenanceIntoEverySubChapter() {
        let text = String(repeating: "饒舌の話。", count: 1_200)
        let readings = [SourceReading(start: 0, length: 2, surface: "饒舌",
                                      reading: "じょうぜつ", rawReading: "じようぜつ")]
        let parts = Chapter(text: text, sourceReadings: readings, isFlattenedSource: true)
            .splitToRenderable()

        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy(\.isFlattenedSource))
        XCTAssertEqual(parts.first?.sourceReadings.first?.rawReading, "じようぜつ")
    }

    func testRoundTripsReadings() throws {
        let c = Chapter(text: "黄前久美子",
                        sourceReadings: [SourceReading(start: 0, length: 1, surface: "黄", reading: "おう")])
        let back = try JSONDecoder().decode(Chapter.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.sourceReadings, c.sourceReadings)
    }

    func testDropsAnnotationsThatNoLongerDescribeTheText() {
        let text = "黄前久美子"
        let good = SourceReading(start: 0, length: 1, surface: "黄", reading: "おう")
        let moved = SourceReading(start: 2, length: 1, surface: "黄", reading: "おう")
        let past = SourceReading(start: 90, length: 1, surface: "黄", reading: "おう")
        XCTAssertEqual([good, moved, past].validated(against: text), [good])
    }

    func testACorruptedOffsetIsRejectedInsteadOfOverflowing() {
        let poison = SourceReading(start: .max, length: 5, surface: "黄", reading: "おう")
        XCTAssertEqual(poison.end, .max, "the end must saturate rather than trap")
        XCTAssertEqual([poison].validated(against: "黄前"), [])
    }

    func testDecodesAChapterWhoseStoredOffsetWouldOverflow() throws {
        let corrupt = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","text":"黄前",
         "sourceReadings":[{"start":9223372036854775807,"length":5,"surface":"黄","reading":"おう"}]}
        """
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(corrupt.utf8))
        XCTAssertEqual(chapter.text, "黄前")
        XCTAssertEqual(chapter.sourceReadings.validated(against: chapter.text), [])
        XCTAssertEqual(chapter.splitToRenderable(maxChars: 1).map(\.text).joined(), "黄前")
    }

    func testSplitRebasesReadingsOntoEachPart() {
        let para = String(repeating: "あ", count: 2_000) + "。\n\n"
        let text = para + "黄前" + para
        let index = para.count
        let chapter = Chapter(title: "章", text: text, sourceReadings: [
            SourceReading(start: index, length: 1, surface: "黄", reading: "おう"),
            SourceReading(start: index + 1, length: 1, surface: "前", reading: "まえ"),
        ])
        let parts = chapter.splitToRenderable(maxChars: 2_100)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.map(\.text).joined(), text, "the split must stay lossless")

        for part in parts {
            for r in part.sourceReadings {
                let chars = Array(part.text)
                XCTAssertLessThanOrEqual(r.end, chars.count)
                XCTAssertEqual(String(chars[r.start..<r.end]), r.surface)
            }
        }
        XCTAssertEqual(parts.flatMap(\.sourceReadings).count, 2, "no annotation should be lost")
    }

    func testSourceReadingOverridesTheTokenizer() throws {
        let text = "黄前久美子は一年生。"
        let tokens = try MeCabTokenizer().tokenize(text)
        let readings = [
            SourceReading(start: 0, length: 1, surface: "黄", reading: "おう"),
            SourceReading(start: 1, length: 1, surface: "前", reading: "まえ"),
        ]
        let out = SourceReadingOverlay.apply(readings, to: tokens, text: text)

        XCTAssertEqual(out.map(\.surface), tokens.map(\.surface), "segmentation must not change")
        XCTAssertEqual(out.first(where: { $0.surface == "黄" })?.reading, "おう")
        XCTAssertEqual(out.first(where: { $0.surface == "前" })?.reading, "まえ")
        XCTAssertNotEqual(out.first(where: { $0.surface == "黄" })?.reading, "き")
        XCTAssertEqual(out.first(where: { $0.surface == "久美子" })?.reading, "くみこ")
        XCTAssertEqual(out.map(\.dictionaryForm), tokens.map(\.dictionaryForm))
    }

    func testConcatenatesAnnotationsThatTileOneToken() throws {
        let text = "秀一"
        let tokens = try MeCabTokenizer().tokenize(text)
        try XCTSkipUnless(tokens.count == 1 && tokens[0].surface == "秀一",
                          "this test describes the case where MeCab keeps 秀一 whole")
        let out = SourceReadingOverlay.apply([
            SourceReading(start: 0, length: 1, surface: "秀", reading: "しゅう"),
            SourceReading(start: 1, length: 1, surface: "一", reading: "いち"),
        ], to: tokens, text: text)

        XCTAssertEqual(out.map(\.surface), tokens.map(\.surface), "segmentation must not change")
        XCTAssertEqual(out.first?.reading, "しゅういち")
        XCTAssertEqual(out.map(\.dictionaryForm), tokens.map(\.dictionaryForm))
    }

    func testDoesNotApplyARunThatUnderfillsAToken() throws {
        let text = "秀一"
        let tokens = try MeCabTokenizer().tokenize(text)
        try XCTSkipUnless(tokens.count == 1, "this test describes the single-token case")
        let out = SourceReadingOverlay.apply(
            [SourceReading(start: 0, length: 1, surface: "秀", reading: "しゅう")],
            to: tokens, text: text)
        XCTAssertEqual(out, tokens)
    }

    func testComposesAStemAnnotationWithTheTokensBareOkurigana() throws {
        let text = "響け"
        let tokens = try MeCabTokenizer().tokenize(text)
        try XCTSkipUnless(tokens.count == 1 && tokens[0].surface == "響け",
                          "this test describes the case where MeCab keeps 響け whole")
        let book = SourceReadingOverlay.bookReadings(
            [SourceReading(start: 0, length: 1, surface: "響", reading: "ひび")],
            tokens: tokens, text: text)

        XCTAssertEqual(book, ["ひびけ"],
                       "ruby marks the kanji stem and leaves the okurigana bare, so the token's "
                           + "book reading is the stem plus the kana it did not annotate")
    }

    func testComposesWhenTheAnnotationIsNotAtTheTokenStart() {
        let book = SourceReadingOverlay.bookReadings(
            [SourceReading(start: 1, length: 1, surface: "茶", reading: "ちゃ")],
            tokens: [Token(surface: "お茶")], text: "お茶")

        XCTAssertEqual(book, ["おちゃ"])
    }

    func testComposesAcrossKatakanaAndTheLongVowelMark() {
        let book = SourceReadingOverlay.bookReadings(
            [SourceReading(start: 0, length: 1, surface: "缶", reading: "かん")],
            tokens: [Token(surface: "缶コーヒー")], text: "缶コーヒー")

        XCTAssertEqual(book, ["かんコーヒー"])
    }

    func testRefusesToComposeOverAnythingThatIsNotKana() {
        let book = SourceReadingOverlay.bookReadings(
            [SourceReading(start: 0, length: 1, surface: "響", reading: "ひび")],
            tokens: [Token(surface: "響A")], text: "響A")

        XCTAssertEqual(book, [nil],
                       "the book said nothing about how to read A, and guessing is how a wrong "
                           + "reading reaches a paid narration")
    }

    func testATokenTheBookNeverAnnotatedHasNoBookReading() {
        let book = SourceReadingOverlay.bookReadings(
            [SourceReading(start: 0, length: 1, surface: "響", reading: "ひび")],
            tokens: [Token(surface: "響け"), Token(surface: "ユーフォニアム")],
            text: "響けユーフォニアム")

        XCTAssertEqual(book, ["ひびけ", nil])
    }

    func testDoesNotApplyAnAnnotationThatSpansTokens() throws {
        let text = "川島緑輝"
        let tokens = try MeCabTokenizer().tokenize(text)
        try XCTSkipUnless(tokens.contains { $0.surface == "緑" } && tokens.contains { $0.surface == "輝" },
                          "this test describes the case where MeCab splits 緑輝")
        let out = SourceReadingOverlay.apply(
            [SourceReading(start: 2, length: 2, surface: "緑輝", reading: "サファイア")],
            to: tokens, text: text)
        XCTAssertEqual(out, tokens)
    }
}
