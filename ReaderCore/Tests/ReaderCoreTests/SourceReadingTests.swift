import XCTest
@testable import ReaderCore

/// Publisher ruby is the only source for readings the tokenizer cannot infer.
/// These pin the three places it can go wrong: decoding a library written before it
/// existed, surviving a chapter split, and landing on the right token.
final class SourceReadingTests: XCTestCase {

    // MARK: - Persistence

    /// THE dangerous one. `library.json` is the only copy of every imported book's
    /// text, and `DiskLibraryStore` responds to an undecodable library by starting
    /// empty and moving the file aside as `.corrupt`. Swift's synthesized decoder
    /// does not fall back to a property's default when the key is absent, so adding
    /// `sourceReadings` without a hand-written `init(from:)` would have emptied every
    /// existing shelf on upgrade.
    func testDecodesAChapterWrittenBeforeSourceReadingsExisted() throws {
        let legacy = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","title":"一","text":"吾輩は猫である。"}
        """
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(legacy.utf8))
        XCTAssertEqual(chapter.text, "吾輩は猫である。")
        XCTAssertEqual(chapter.title, "一")
        XCTAssertEqual(chapter.sourceReadings, [])
    }

    /// A whole library must survive too — the store decodes `[Document]`, so one bad
    /// chapter anywhere loses everything.
    func testDecodesALegacyLibraryDocument() throws {
        let legacy = """
        [{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","title":"本",
          "chapters":[{"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3302","text":"あ"}],
          "progress":{"chapterIndex":0,"time":0,"fraction":0}}]
        """
        let docs = try JSONDecoder().decode([Document].self, from: Data(legacy.utf8))
        XCTAssertEqual(docs.first?.chapters.first?.text, "あ")
    }

    /// Metadata corruption must cost the annotations, never the text.
    func testMalformedAnnotationsDoNotCostTheChapterText() throws {
        let broken = """
        {"id":"3F2504E0-4F89-11D3-9A0C-0305E82C3301","text":"あ","sourceReadings":"nonsense"}
        """
        let chapter = try JSONDecoder().decode(Chapter.self, from: Data(broken.utf8))
        XCTAssertEqual(chapter.text, "あ")
        XCTAssertEqual(chapter.sourceReadings, [])
    }

    /// Books with no ruby must encode exactly as before, so an older build can still
    /// read a library a newer one wrote.
    func testOmitsTheKeyWhenThereAreNoReadings() throws {
        let data = try JSONEncoder().encode(Chapter(text: "あ"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("sourceReadings"))
    }

    func testRoundTripsReadings() throws {
        let c = Chapter(text: "黄前久美子",
                        sourceReadings: [SourceReading(start: 0, length: 1, surface: "黄", reading: "おう")])
        let back = try JSONDecoder().decode(Chapter.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.sourceReadings, c.sourceReadings)
    }

    // MARK: - Validation

    func testDropsAnnotationsThatNoLongerDescribeTheText() {
        let text = "黄前久美子"
        let good = SourceReading(start: 0, length: 1, surface: "黄", reading: "おう")
        let moved = SourceReading(start: 2, length: 1, surface: "黄", reading: "おう")  // says 黄, extracts 久
        let past = SourceReading(start: 90, length: 1, surface: "黄", reading: "おう")
        XCTAssertEqual([good, moved, past].validated(against: text), [good])
    }

    // MARK: - Splitting

    /// Offsets index the WHOLE chapter, so a part starting at character N would carry
    /// annotations pointing N characters past its own end.
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

        // Every surviving annotation must still extract its own surface from the part
        // it now belongs to — the property that makes rebasing safe.
        for part in parts {
            for r in part.sourceReadings {
                let chars = Array(part.text)
                XCTAssertLessThanOrEqual(r.end, chars.count)
                XCTAssertEqual(String(chars[r.start..<r.end]), r.surface)
            }
        }
        XCTAssertEqual(parts.flatMap(\.sourceReadings).count, 2, "no annotation should be lost")
    }

    // MARK: - Overlay

    func testSourceReadingOverridesTheTokenizer() throws {
        let text = "黄前久美子は一年生。"
        let tokens = try MeCabTokenizer().tokenize(text)
        // What the book says, one <rb>/<rt> pair each — the granularity the markup uses.
        let readings = [
            SourceReading(start: 0, length: 1, surface: "黄", reading: "おう"),
            SourceReading(start: 1, length: 1, surface: "前", reading: "まえ"),
        ]
        let out = SourceReadingOverlay.apply(readings, to: tokens, text: text)

        XCTAssertEqual(out.map(\.surface), tokens.map(\.surface), "segmentation must not change")
        XCTAssertEqual(out.first(where: { $0.surface == "黄" })?.reading, "おう")
        XCTAssertEqual(out.first(where: { $0.surface == "前" })?.reading, "まえ")
        // MeCab's own reading for 黄前 is きぜん; the point of the exercise is that it
        // no longer reaches the page.
        XCTAssertNotEqual(out.first(where: { $0.surface == "黄" })?.reading, "き")
        // Untouched tokens keep MeCab's reading and every token keeps its lemma.
        XCTAssertEqual(out.first(where: { $0.surface == "久美子" })?.reading, "くみこ")
        XCTAssertEqual(out.map(\.dictionaryForm), tokens.map(\.dictionaryForm))
    }

    /// Ruby finer than the tokenizer's segmentation: the book writes 秀一 as two pairs
    /// (秀/しゅう, 一/いち) while MeCab keeps 秀一 whole and reads it ひでかず. The run
    /// tiles the token exactly, so the concatenated reading wins — otherwise per-character
    /// ruby loses against any coarser token and a character's name is read wrong.
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

    /// A run that only covers PART of a token must not be applied — a partial reading is
    /// worse than the tokenizer's whole one.
    func testDoesNotApplyARunThatUnderfillsAToken() throws {
        let text = "秀一"
        let tokens = try MeCabTokenizer().tokenize(text)
        try XCTSkipUnless(tokens.count == 1, "this test describes the single-token case")
        let out = SourceReadingOverlay.apply(
            [SourceReading(start: 0, length: 1, surface: "秀", reading: "しゅう")],
            to: tokens, text: text)
        XCTAssertEqual(out, tokens)
    }

    /// An annotation whose base spans several tokens is carried but not applied:
    /// putting サファイア on 緑 alone would leave 輝 bare, and giving both tokens the
    /// same interval makes `SpanTimeline.index(at:)` — a rightmost search — skip the
    /// first one forever. Rendering that case needs range-based ruby, not this.
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
