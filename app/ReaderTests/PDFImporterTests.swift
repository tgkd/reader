import XCTest
import ReaderCore
@testable import Reader

/// Exercises the real `PDFImporter` (PDFKit) over generated PDFs: one chapter per
/// page, blank pages skipped, and the unreadable error case. Page text is ASCII so
/// extraction assertions don't depend on PDFKit's CJK glyph handling.
final class PDFImporterTests: XCTestCase {
    private func chapters(_ url: URL, recognizer: PDFTextRecognizer? = nil) async throws -> [Chapter] {
        try await PDFImporter(url: url, recognizer: recognizer).chapters()
    }

    func testSinglePageBecomesSingleChapter() async throws {
        let url = Fixture.pdf(pages: ["Alpha page"])
        let result = try await chapters(url)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].text.contains("Alpha"), result[0].text)
    }

    func testEachPageBecomesAChapterInOrder() async throws {
        let url = Fixture.pdf(pages: ["Alpha", "Bravo", "Charlie"])
        let result = try await chapters(url)
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result[0].text.contains("Alpha"))
        XCTAssertTrue(result[1].text.contains("Bravo"))
        XCTAssertTrue(result[2].text.contains("Charlie"))
    }

    func testBlankPagesAreSkipped() async throws {
        let url = Fixture.pdf(pages: ["Alpha", "", "Bravo"])
        let result = try await chapters(url)
        XCTAssertEqual(result.count, 2)   // the blank middle page is dropped
        XCTAssertTrue(result[0].text.contains("Alpha"))
        XCTAssertTrue(result[1].text.contains("Bravo"))
    }

    func testNonPDFThrowsUnreadable() async {
        let url = Fixture.write(Data("not a pdf".utf8), ext: "pdf")
        do {
            _ = try await chapters(url)
            XCTFail("expected unreadable")
        } catch {
            XCTAssertEqual(error as? ImportError, .unreadable)
        }
    }

    // MARK: - OCR fallback (pages with no text layer)

    /// A page with no text layer is OCR'd; recovered text becomes the chapter, in
    /// page order. Born-digital pages (real text layer) NEVER invoke the recognizer.
    func testScannedPagesAreOCRdInOrderAndTextLayerBypassesOCR() async throws {
        let url = Fixture.imagePDF(["スキャン一", "スキャン二"])
        let stub = StubRecognizer(perImage: ["認識テキストA", "認識テキストB"])
        let result = try await chapters(url, recognizer: stub)
        XCTAssertEqual(result.map(\.text), ["認識テキストA", "認識テキストB"])
        XCTAssertEqual(stub.callCount, 1)              // one batched call
        XCTAssertEqual(stub.imageCount, 2)            // both scanned pages
    }

    func testTextLayerPageDoesNotInvokeRecognizer() async throws {
        let url = Fixture.pdf(pages: ["Real text layer"])   // selectable glyphs
        let stub = StubRecognizer(perImage: ["SHOULD NOT APPEAR"])
        let result = try await chapters(url, recognizer: stub)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].text.contains("Real text layer"))
        XCTAssertEqual(stub.imageCount, 0)            // OCR never ran
    }

    func testScannedPDFWithNoRecognizerThrowsOCRUnavailable() async {
        let url = Fixture.imagePDF(["スキャン"])
        do {
            _ = try await chapters(url, recognizer: nil)
            XCTFail("expected ocrUnavailable")
        } catch {
            XCTAssertEqual(error as? ImportError, .ocrUnavailable)
        }
    }

    func testOCRYieldingNothingThrowsOCRFailed() async {
        let url = Fixture.imagePDF(["スキャン一", "スキャン二"])
        let stub = StubRecognizer(perImage: ["", "   "])   // OCR recovered nothing
        do {
            _ = try await chapters(url, recognizer: stub)
            XCTFail("expected ocrFailed")
        } catch {
            XCTAssertEqual(error as? ImportError, .ocrFailed)
        }
    }

    /// More OCR pages than the render window → multiple render/recognize passes
    /// (bounded memory). Recovered text must stay in global page order across passes.
    func testOCRWindowingPreservesOrderAcrossWindows() async throws {
        let url = Fixture.imagePDF((0..<10).map { "page\($0)" })
        let counter = OCRCounter()
        let result = try await chapters(url, recognizer: counter)
        XCTAssertEqual(result.map(\.text), (0..<10).map { "P\($0)" })
        XCTAssertGreaterThanOrEqual(counter.calls, 2)   // processed in >1 window
    }
}
