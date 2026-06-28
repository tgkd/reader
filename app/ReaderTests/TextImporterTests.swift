import XCTest
import ReaderCore
@testable import Reader

/// Exercises the real `TextImporter` (whole file → one chapter) across the
/// encodings `JapaneseTextDecoder` sniffs, plus the empty-input error case.
final class TextImporterTests: XCTestCase {
    private let sample = "吾輩は猫である。\n名前はまだ無い。"

    private func text(_ url: URL) throws -> String {
        let chapters = try TextImporter(url: url).chapters()
        XCTAssertEqual(chapters.count, 1)   // the whole file is a single chapter
        return chapters[0].text
    }

    func testUTF8() throws {
        let url = Fixture.textFile(sample, encoding: .utf8)
        XCTAssertEqual(try text(url), sample)
    }

    func testShiftJIS() throws {
        let url = Fixture.textFile(sample, encoding: .shiftJIS)
        XCTAssertEqual(try text(url), sample)
    }

    func testEUCJP() throws {
        let url = Fixture.textFile(sample, encoding: .japaneseEUC)
        XCTAssertEqual(try text(url), sample)
    }

    func testUTF8BOMIsStripped() throws {
        let url = Fixture.textFile(sample, encoding: .utf8, bom: [0xEF, 0xBB, 0xBF])
        let decoded = try text(url)
        XCTAssertEqual(decoded, sample)
        XCTAssertFalse(decoded.unicodeScalars.contains("\u{FEFF}"))   // BOM gone
    }

    func testTextExtensionAlsoWorks() throws {
        let url = Fixture.textFile(sample, encoding: .utf8, ext: "text")
        XCTAssertEqual(try text(url), sample)
    }

    func testWhitespaceOnlyThrowsUnreadable() {
        let url = Fixture.textFile("   \n\t  \n", encoding: .utf8)
        XCTAssertThrowsError(try TextImporter(url: url).chapters()) {
            XCTAssertEqual($0 as? ImportError, .unreadable)
        }
    }
}
