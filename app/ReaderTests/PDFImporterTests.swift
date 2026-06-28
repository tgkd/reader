import XCTest
import ReaderCore
@testable import Reader

/// Exercises the real `PDFImporter` (PDFKit) over generated PDFs: one chapter per
/// page, blank pages skipped, and the unreadable error case. Page text is ASCII so
/// extraction assertions don't depend on PDFKit's CJK glyph handling.
final class PDFImporterTests: XCTestCase {
    private func chapters(_ url: URL) throws -> [Chapter] {
        try PDFImporter(url: url).chapters()
    }

    func testSinglePageBecomesSingleChapter() throws {
        let url = Fixture.pdf(pages: ["Alpha page"])
        let result = try chapters(url)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].text.contains("Alpha"), result[0].text)
    }

    func testEachPageBecomesAChapterInOrder() throws {
        let url = Fixture.pdf(pages: ["Alpha", "Bravo", "Charlie"])
        let result = try chapters(url)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0].text.contains("Alpha"))
        XCTAssertTrue(result[1].text.contains("Bravo"))
        XCTAssertTrue(result[2].text.contains("Charlie"))
    }

    func testBlankPagesAreSkipped() throws {
        let url = Fixture.pdf(pages: ["Alpha", "", "Bravo"])
        let result = try chapters(url)
        XCTAssertEqual(result.count, 2)   // the blank middle page is dropped
        XCTAssertTrue(result[0].text.contains("Alpha"))
        XCTAssertTrue(result[1].text.contains("Bravo"))
    }

    func testNonPDFThrowsUnreadable() {
        let url = Fixture.write(Data("not a pdf".utf8), ext: "pdf")
        XCTAssertThrowsError(try chapters(url)) {
            XCTAssertEqual($0 as? ImportError, .unreadable)
        }
    }
}
