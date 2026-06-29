import XCTest
import ReaderCore
@testable import Reader

/// Exercises the real `TextImporter` (whole file → one chapter) across the
/// encodings `JapaneseTextDecoder` sniffs, plus the empty-input error case.
final class TextImporterTests: XCTestCase {
    private let sample = "吾輩は猫である。\n名前はまだ無い。"

    private func text(_ url: URL) async throws -> String {
        let chapters = try await TextImporter(url: url).chapters()
        XCTAssertEqual(chapters.count, 1)   // the whole file is a single chapter
        return chapters[0].text
    }

    func testUTF8() async throws {
        let url = Fixture.textFile(sample, encoding: .utf8)
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
    }

    func testShiftJIS() async throws {
        let url = Fixture.textFile(sample, encoding: .shiftJIS)
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
    }

    func testEUCJP() async throws {
        let url = Fixture.textFile(sample, encoding: .japaneseEUC)
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
    }

    func testUTF8BOMIsStripped() async throws {
        let url = Fixture.textFile(sample, encoding: .utf8, bom: [0xEF, 0xBB, 0xBF])
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
        XCTAssertFalse(decoded.unicodeScalars.contains("\u{FEFF}"))   // BOM gone
    }

    func testTextExtensionAlsoWorks() async throws {
        let url = Fixture.textFile(sample, encoding: .utf8, ext: "text")
        let decoded = try await text(url)
        XCTAssertEqual(decoded, sample)
    }

    func testWhitespaceOnlyThrowsUnreadable() async {
        let url = Fixture.textFile("   \n\t  \n", encoding: .utf8)
        do {
            _ = try await TextImporter(url: url).chapters()
            XCTFail("expected unreadable")
        } catch {
            XCTAssertEqual(error as? ImportError, .unreadable)
        }
    }
}
