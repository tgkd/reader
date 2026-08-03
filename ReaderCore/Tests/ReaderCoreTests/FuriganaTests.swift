import XCTest
@testable import ReaderCore

final class FuriganaTests: XCTestCase {
    private func place(_ surface: String, _ reading: String?) -> (String, String)? {
        guard let p = Furigana.place(surface: surface, reading: reading) else { return nil }
        let chars = Array(surface)
        return (String(chars[p.range]), p.reading)
    }

    func testTrimsSharedTrailingOkurigana() {
        XCTAssertEqual(place("生れ", "うまれ").map { [$0.0, $0.1] }, ["生", "うま"])
        XCTAssertEqual(place("泣い", "ない").map { [$0.0, $0.1] }, ["泣", "な"])
        XCTAssertEqual(place("見た", "みた").map { [$0.0, $0.1] }, ["見", "み"])
    }

    func testTrimsSharedLeadingKana() {
        XCTAssertEqual(place("いた事", "いたこと").map { [$0.0, $0.1] }, ["事", "こと"])
        XCTAssertEqual(place("お茶", "おちゃ").map { [$0.0, $0.1] }, ["茶", "ちゃ"])
    }

    func testTrimsBothEnds() {
        XCTAssertEqual(place("大きい", "おおきい").map { [$0.0, $0.1] }, ["大", "おお"])
        XCTAssertEqual(place("行っ", "いっ").map { [$0.0, $0.1] }, ["行", "い"])
    }

    func testLeavesPureKanjiCompoundsAlone() {
        XCTAssertEqual(place("見当", "けんとう").map { [$0.0, $0.1] }, ["見当", "けんとう"])
        XCTAssertEqual(place("記憶", "きおく").map { [$0.0, $0.1] }, ["記憶", "きおく"])
        XCTAssertEqual(place("吾輩", "わがはい").map { [$0.0, $0.1] }, ["吾輩", "わがはい"])
        XCTAssertEqual(place("名前", "なまえ").map { [$0.0, $0.1] }, ["名前", "なまえ"])
    }

    func testInteriorOkuriganaFallsBackToWholeToken() {
        XCTAssertEqual(place("取り消し", "とりけし").map { [$0.0, $0.1] }, ["取り消", "とりけ"])
    }

    func testNoFuriganaWithoutKanjiOrReading() {
        XCTAssertNil(Furigana.place(surface: "どこ", reading: "どこ"))
        XCTAssertNil(Furigana.place(surface: "ニャーニャー", reading: "にゃーにゃー"))
        XCTAssertNil(Furigana.place(surface: "見当", reading: nil))
        XCTAssertNil(Furigana.place(surface: "見当", reading: ""))
        XCTAssertNil(Furigana.place(surface: "\n", reading: nil))
    }

    func testIdenticalSurfaceAndReadingNeverProducesAnEmptyRange() throws {
        let p = try XCTUnwrap(Furigana.place(surface: "生", reading: "生"))
        XCTAssertEqual(p.range, 0..<1)
        XCTAssertEqual(p.reading, "生")
    }

    func testSupplementaryPlaneKanjiCountsAsKanji() {
        XCTAssertTrue(Furigana.isKanji("𠮷"), "extension B ideographs are kanji")
        XCTAssertTrue(Furigana.isKanji("﨑"), "compatibility ideographs are kanji")
        XCTAssertEqual(place("𠮷野", "よしの").map { [$0.0, $0.1] }, ["𠮷野", "よしの"])
        XCTAssertEqual(place("𠮷", "よし").map { [$0.0, $0.1] }, ["𠮷", "よし"])
    }

    func testIdeographBlockBoundaries() throws {
        let inside: [UInt32] = [0x3400, 0x4DBF, 0x4E00, 0x9FFF, 0xF900, 0xFAFF,
                                0x20000, 0x2EBEF, 0x2EBF0, 0x2EE5D,
                                0x2F800, 0x2FA1F, 0x30000, 0x323AF]
        let outside: [UInt32] = [0x33FF, 0x4DC0, 0xA000, 0xF8FF, 0xFB00,
                                 0x1FFFF, 0x2EE5E, 0x2F7FF, 0x2FA20, 0x2FFFF, 0x323B0,
                                 0x3042, 0x30A2]
        for v in inside {
            let scalar = try XCTUnwrap(Unicode.Scalar(v))
            XCTAssertTrue(Furigana.isIdeograph(scalar), String(format: "U+%04X", v))
        }
        for v in outside {
            let scalar = try XCTUnwrap(Unicode.Scalar(v))
            XCTAssertFalse(Furigana.isIdeograph(scalar), String(format: "U+%04X", v))
        }
        XCTAssertTrue(Furigana.isKanji("\u{2EBF0}"), "extension I ideographs are kanji")
    }

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
