import XCTest
@testable import ReaderCore

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
        XCTAssertEqual(decoded, sample)
        XCTAssertFalse(decoded?.hasPrefix("\u{FEFF}") ?? true)
    }

    func testShiftJISNotMisreadAsUTF8() throws {
        let data = try XCTUnwrap(sample.data(using: .shiftJIS))
        let decoded = try XCTUnwrap(JapaneseTextDecoder.decode(data))
        XCTAssertFalse(decoded.unicodeScalars.contains("\u{FFFD}"))
        XCTAssertEqual(decoded, sample)
    }

    func testEmptyDataDecodesToEmptyString() {
        XCTAssertEqual(JapaneseTextDecoder.decode(Data()), "")
    }

    func testEUCJPKanaNotMisreadAsShiftJIS() throws {
        let kana = "きょうはいいてんきですね。さくらがさきました。"
        let data = try XCTUnwrap(kana.data(using: .japaneseEUC))
        let decoded = try XCTUnwrap(JapaneseTextDecoder.decode(data))
        XCTAssertEqual(decoded, kana)
        XCTAssertFalse(decoded.unicodeScalars.contains { (0xFF61...0xFF9F).contains($0.value) },
                       "must not be half-width-katakana mojibake, got \(decoded)")
    }

    func testCorruptedUTF8DegradesInsteadOfNil() {
        var data = Data(sample.utf8)
        data.removeLast()
        XCTAssertNotNil(JapaneseTextDecoder.decode(data))
    }
}
