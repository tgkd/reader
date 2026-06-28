import XCTest
import ReaderCore
@testable import Reader

/// Exercises `Importer` — the extension→importer routing and `document(from:)`
/// assembly (title from filename, chapter order, unsupported/empty errors).
final class ImporterRoutingTests: XCTestCase {

    func testExtensionRouting() {
        func importer(_ name: String) -> DocumentImporter? {
            Importer.importer(for: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        XCTAssertTrue(importer("book.epub") is EPUBImporter)
        XCTAssertTrue(importer("book.pdf") is PDFImporter)
        XCTAssertTrue(importer("book.txt") is TextImporter)
        XCTAssertTrue(importer("book.text") is TextImporter)
        XCTAssertTrue(importer("README") is TextImporter)        // no extension → text
        XCTAssertTrue(importer("BOOK.EPUB") is EPUBImporter)     // case-insensitive
        XCTAssertNil(importer("book.docx"))                       // unsupported
    }

    func testUnsupportedExtensionThrows() {
        let url = URL(fileURLWithPath: "/tmp/whatever.docx")
        XCTAssertThrowsError(try Importer.document(from: url)) {
            XCTAssertEqual($0 as? ImportError, .unsupported)
        }
    }

    func testDocumentFromEPUBKeepsChapterOrderAndTitlesFromFilename() throws {
        let epub = try Fixture.simpleEPUB(["第一章の本文", "第二章の本文"])
        let named = Fixture.renamed(epub, to: "銀河鉄道の夜.epub")
        let doc = try Importer.document(from: named)
        XCTAssertEqual(doc.title, "銀河鉄道の夜")
        XCTAssertEqual(doc.chapters.map(\.text), ["第一章の本文", "第二章の本文"])
    }

    func testDocumentFromTextFile() throws {
        let url = Fixture.renamed(Fixture.textFile("ただのテキスト", encoding: .utf8), to: "メモ.txt")
        let doc = try Importer.document(from: url)
        XCTAssertEqual(doc.title, "メモ")
        XCTAssertEqual(doc.chapters.count, 1)
        XCTAssertEqual(doc.chapters[0].text, "ただのテキスト")
    }

    func testSupportedExtensionsList() {
        XCTAssertEqual(Set(Importer.supportedExtensions), ["epub", "pdf", "txt", "text"])
    }
}
