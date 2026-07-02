import XCTest
@testable import ReaderCore

/// `JapaneseTextDecoder` sniffs the encoding of `.txt` imports. These pin that
/// each of the three real-world Japanese encodings round-trips, that a UTF-8 BOM
/// is stripped, and — the important one — that a wrong guess is rejected via the
/// mojibake (U+FFFD) check instead of returning garbage.
final class JapaneseTextDecoderTests: XCTestCase {
    private let sample = "吾輩は猫である。名前はまだ無い。"

    func testUTF8RoundTrip() {
        let data = Data(sample.utf8)
        XCTAssertEqual(JapaneseTextDecoder.decode(data), sample)
    }

    func testShiftJISRoundTrip() throws {
        let data = try XCTUnwrap(sample.data(using: .shiftJIS), "couldn't encode Shift-JIS")
        XCTAssertEqual(JapaneseTextDecoder.decode(data), sample)
    }

    func testEUCJPRoundTrip() throws {
        let data = try XCTUnwrap(sample.data(using: .japaneseEUC), "couldn't encode EUC-JP")
        XCTAssertEqual(JapaneseTextDecoder.decode(data), sample)
    }

    func testUTF8BOMStripped() {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(sample.utf8))
        let decoded = JapaneseTextDecoder.decode(data)
        XCTAssertEqual(decoded, sample)                 // BOM not part of the text
        XCTAssertFalse(decoded?.hasPrefix("\u{FEFF}") ?? true)
    }

    func testShiftJISNotMisreadAsUTF8() throws {
        // Shift-JIS bytes are (almost always) invalid UTF-8, so UTF-8 decode fails
        // outright and we fall through to Shift-JIS — never returning mojibake.
        let data = try XCTUnwrap(sample.data(using: .shiftJIS))
        let decoded = try XCTUnwrap(JapaneseTextDecoder.decode(data))
        XCTAssertFalse(decoded.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertEqual(decoded, sample)
    }

    func testEmptyDataDecodesToEmptyString() {
        XCTAssertEqual(JapaneseTextDecoder.decode(Data()), "")
    }

    func testEUCJPKanaNotMisreadAsShiftJIS() throws {
        // Hiragana-heavy EUC-JP bytes decode "validly" (no U+FFFD) as Shift-JIS
        // half-width-katakana garbage, so a first-success-by-order sniff returns
        // mojibake. The plausibility score must pick the real EUC-JP decode.
        let kana = "きょうはいいてんきですね。さくらがさきました。"
        let data = try XCTUnwrap(kana.data(using: .japaneseEUC))
        let decoded = try XCTUnwrap(JapaneseTextDecoder.decode(data))
        XCTAssertEqual(decoded, kana)
        XCTAssertFalse(decoded.unicodeScalars.contains { (0xFF61...0xFF9F).contains($0.value) },
                       "must not be half-width-katakana mojibake, got \(decoded)")
    }

    func testCorruptedUTF8DegradesInsteadOfNil() {
        // A valid UTF-8 passage with a truncated final multi-byte char must still
        // return SOMETHING (repairing decode), never nil.
        var data = Data(sample.utf8)
        data.removeLast()   // lop a byte off the trailing multi-byte char
        XCTAssertNotNil(JapaneseTextDecoder.decode(data))
    }
}
