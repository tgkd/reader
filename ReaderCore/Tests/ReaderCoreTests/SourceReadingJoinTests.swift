import XCTest
@testable import ReaderCore

final class SourceReadingJoinTests: XCTestCase {
    private func reading(_ start: Int, _ surface: String, _ reading: String) -> SourceReading {
        SourceReading(start: start, length: surface.count, surface: surface, reading: reading)
    }

    func testAnnotationSpanningTwoTokensStillWins() {
        let text = "仰向に寝た女がいる。"
        let tokens = [Token(surface: "仰", reading: "オッシャ", dictionaryForm: "仰る"),
                      Token(surface: "向", reading: "ムコウ", dictionaryForm: "向"),
                      Token(surface: "に寝た女がいる。", reading: "ニネタオンナガイル。")]
        let out = SourceReadingOverlay.apply([reading(0, "仰向", "あおむけ")],
                                             to: tokens, text: text)
        XCTAssertEqual(out[0].surface, "仰向")
        XCTAssertEqual(out[0].reading, "あおむけ",
                       "the book spelled this word out; the tokenizer's guess must not outrank it")
    }

    func testJoiningPreservesTheStreamInvariants() {
        let text = "兵十は二人で歩いた。"
        let tokens = [Token(surface: "兵", reading: "ヘイ"), Token(surface: "十", reading: "ジュウ"),
                      Token(surface: "は", reading: "ハ"),
                      Token(surface: "二", reading: "ニ"), Token(surface: "人", reading: "ニン"),
                      Token(surface: "で歩いた。", reading: "デアルイタ。")]
        let out = SourceReadingOverlay.apply(
            [reading(0, "兵十", "ひょうじゅう"), reading(3, "二人", "ふたり")],
            to: tokens, text: text)

        XCTAssertEqual(out.map(\.surface).joined(), text,
                       "surfaces must still concatenate to the chapter text")
        XCTAssertEqual(out.reduce(0) { $0 + $1.surface.count }, text.count,
                       "the character count is what saved offsets and the lexicon walk")
        XCTAssertEqual(out.map(\.reading), ["ひょうじゅう", "ハ", "ふたり", "デアルイタ。"])
    }

    func testAJoinedTokenCarriesNoLemmaOfItsParts() {
        let text = "仰向"
        let tokens = [Token(surface: "仰", reading: "オッシャ", dictionaryForm: "仰る"),
                      Token(surface: "向", reading: "ムコウ", dictionaryForm: "向く")]
        let out = SourceReadingOverlay.apply([reading(0, "仰向", "あおむけ")], to: tokens, text: text)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].dictionaryForm,
                     "仰る describes a piece, not the word — tap-to-define falls back to the surface")
    }

    func testAnnotationInsideOneTokenIsUnaffected() {
        let text = "響け"
        let tokens = [Token(surface: "響け", reading: "ヒビケ", dictionaryForm: "響く")]
        let out = SourceReadingOverlay.apply([reading(0, "響", "ひび")], to: tokens, text: text)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].reading, "ひびけ")
        XCTAssertEqual(out[0].dictionaryForm, "響く", "an unjoined token keeps its lemma")
    }

    func testTokensAreUntouchedWithoutAnnotations() {
        let text = "犬が走る。"
        let tokens = [Token(surface: "犬", reading: "イヌ"), Token(surface: "が", reading: "ガ"),
                      Token(surface: "走る。", reading: "ハシル。")]
        XCTAssertEqual(SourceReadingOverlay.apply([], to: tokens, text: text), tokens)
    }

    func testARefusedAnnotationLeavesItsTokensAlone() {
        let text = "御茶碗を持つ。"
        let tokens = [Token(surface: "御茶", reading: "オチャ", dictionaryForm: "御茶"),
                      Token(surface: "碗", reading: "ワン", dictionaryForm: "碗"),
                      Token(surface: "を持つ。", reading: "ヲモツ。")]
        let out = SourceReadingOverlay.apply([reading(1, "茶碗", "ちゃわん")], to: tokens, text: text)
        XCTAssertEqual(out, tokens,
                       "御 is not kana, so bookReadings refuses this annotation — joining the run "
                           + "would cost a lemma and a highlight boundary for nothing")
    }

    func testTwoAnnotationsTilingOneRunStillJoin() {
        let text = "二人三脚"
        let tokens = [Token(surface: "二", reading: "ニ"), Token(surface: "人三", reading: "ニンサン"),
                      Token(surface: "脚", reading: "キャク")]
        let out = SourceReadingOverlay.apply(
            [reading(0, "二人", "ふたり"), reading(2, "三脚", "さんきゃく")], to: tokens, text: text)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].reading, "ふたりさんきゃく",
                       "annotations that tile the run compose; the run must still join")
    }

    func testAJoinRunWithAnUnreadableTokenReportsNoFallbackReading() {
        let text = "犍陀多"
        let tokens = [Token(surface: "犍", reading: nil), Token(surface: "陀", reading: "ダ"),
                      Token(surface: "多", reading: "オオ")]
        let joined = SourceReadingOverlay.joiningAcrossAnnotations(
            [reading(0, "犍陀多", "かんだた")], tokens: tokens, text: text)
        XCTAssertEqual(joined.count, 1)
        XCTAssertNil(joined[0].reading,
                     "a partial concatenation would read as a whole word it is not")
    }
}
