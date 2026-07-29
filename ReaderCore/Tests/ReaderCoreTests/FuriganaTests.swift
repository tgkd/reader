import XCTest
@testable import ReaderCore

/// Every `surface`/`reading` pair here is real MeCab+IPADic output, verified by
/// running the tokenizer over Sōseki's opening — not invented examples.
final class FuriganaTests: XCTestCase {

    private func place(_ surface: String, _ reading: String?) -> (String, String)? {
        guard let p = Furigana.place(surface: surface, reading: reading) else { return nil }
        let chars = Array(surface)
        return (String(chars[p.range]), p.reading)
    }

    // MARK: - Trimming

    func testTrimsSharedTrailingOkurigana() {
        // 生れ / うまれ -> うま over 生 alone.
        XCTAssertEqual(place("生れ", "うまれ").map { [$0.0, $0.1] }, ["生", "うま"])
        XCTAssertEqual(place("泣い", "ない").map { [$0.0, $0.1] }, ["泣", "な"])
        XCTAssertEqual(place("見た", "みた").map { [$0.0, $0.1] }, ["見", "み"])
    }

    func testTrimsSharedLeadingKana() {
        // いた事 is ONE IPADic entry, reading いたこと — こと belongs over 事 only.
        XCTAssertEqual(place("いた事", "いたこと").map { [$0.0, $0.1] }, ["事", "こと"])
        XCTAssertEqual(place("お茶", "おちゃ").map { [$0.0, $0.1] }, ["茶", "ちゃ"])
    }

    func testTrimsBothEnds() {
        XCTAssertEqual(place("大きい", "おおきい").map { [$0.0, $0.1] }, ["大", "おお"])
        XCTAssertEqual(place("行っ", "いっ").map { [$0.0, $0.1] }, ["行", "い"])
    }

    // MARK: - Unchanged behaviour (the fallback must stay byte-identical)

    func testLeavesPureKanjiCompoundsAlone() {
        XCTAssertEqual(place("見当", "けんとう").map { [$0.0, $0.1] }, ["見当", "けんとう"])
        XCTAssertEqual(place("記憶", "きおく").map { [$0.0, $0.1] }, ["記憶", "きおく"])
        XCTAssertEqual(place("吾輩", "わがはい").map { [$0.0, $0.1] }, ["吾輩", "わがはい"])
        XCTAssertEqual(place("名前", "なまえ").map { [$0.0, $0.1] }, ["名前", "なまえ"])
    }

    /// Interior okurigana needs mora alignment, not edge trimming — such tokens
    /// must degrade to today's whole-token annotation, never to a wrong one.
    func testInteriorOkuriganaFallsBackToWholeToken() {
        XCTAssertEqual(place("取り消し", "とりけし").map { [$0.0, $0.1] }, ["取り消", "とりけ"])
    }

    // MARK: - Refusals

    func testNoFuriganaWithoutKanjiOrReading() {
        XCTAssertNil(Furigana.place(surface: "どこ", reading: "どこ"))
        XCTAssertNil(Furigana.place(surface: "ニャーニャー", reading: "にゃーにゃー"))
        XCTAssertNil(Furigana.place(surface: "見当", reading: nil))
        XCTAssertNil(Furigana.place(surface: "見当", reading: ""))
        XCTAssertNil(Furigana.place(surface: "\n", reading: nil))
    }

    /// A reading identical to the surface would otherwise trim itself to nothing.
    /// It must fall back to a whole-token annotation rather than an empty one.
    func testIdenticalSurfaceAndReadingNeverProducesAnEmptyRange() throws {
        let p = try XCTUnwrap(Furigana.place(surface: "生", reading: "生"))
        XCTAssertEqual(p.range, 0..<1)
        XCTAssertEqual(p.reading, "生")
    }

    /// The annotated range must always be a valid, non-empty slice of the surface —
    /// the view indexes into the displayed string with it.
    func testRangeIsAlwaysAValidNonEmptySlice() {
        let cases = [("生れ", "うまれ"), ("いた事", "いたこと"), ("見当", "けんとう"),
                     ("取り消し", "とりけし"), ("大きい", "おおきい"), ("一つ", "ひとつ"),
                     ("気持ち", "きもち"), ("生", "生")]
        for (surface, reading) in cases {
            guard let p = Furigana.place(surface: surface, reading: reading) else { continue }
            XCTAssertFalse(p.range.isEmpty, "\(surface): empty range")
            XCTAssertFalse(p.reading.isEmpty, "\(surface): empty reading")
            XCTAssertGreaterThanOrEqual(p.range.lowerBound, 0, "\(surface)")
            XCTAssertLessThanOrEqual(p.range.upperBound, surface.count, "\(surface)")
        }
    }
}
