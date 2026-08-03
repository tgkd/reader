import XCTest
import ReaderCore
@testable import Reader

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

    func testReportsParsingProgressPerPage() async throws {
        let url = Fixture.pdf(pages: ["Alpha", "Bravo", "Charlie"])
        let progress = ImportProgressRecorder()
        _ = try await PDFImporter(url: url, onParsingProgress: progress.record).chapters()
        XCTAssertEqual(progress.values, [
            ImportProgressSample(completed: 0, total: 3),
            ImportProgressSample(completed: 1, total: 3),
            ImportProgressSample(completed: 2, total: 3),
            ImportProgressSample(completed: 3, total: 3),
        ])
    }

    func testBlankPagesAreSkipped() async throws {
        let url = Fixture.pdf(pages: ["Alpha", "", "Bravo"])
        let result = try await chapters(url)
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result[0].text.contains("Alpha"))
        XCTAssertTrue(result[1].text.contains("Bravo"))
    }

    func testPasswordProtectedPDFThrowsPasswordProtected() async {
        let url = Fixture.lockedPDF()
        do {
            _ = try await chapters(url)
            XCTFail("expected passwordProtected")
        } catch {
            XCTAssertEqual(error as? ImportError, .passwordProtected)
        }
    }

    func testPasswordProtectedPDFNeverRoutesToOCR() async {
        let url = Fixture.lockedPDF()
        XCTAssertEqual(PDFImporter(url: url).ocrCandidateCount(), 0)
        let stub = StubRecognizer(perImage: ["SHOULD NOT APPEAR"])
        do {
            _ = try await chapters(url, recognizer: stub)
            XCTFail("expected passwordProtected")
        } catch {
            XCTAssertEqual(error as? ImportError, .passwordProtected)
            XCTAssertEqual(stub.imageCount, 0)
        }
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

    func testScannedPagesAreOCRdInOrderAndTextLayerBypassesOCR() async throws {
        let url = Fixture.imagePDF(["スキャン一", "スキャン二"])
        let stub = StubRecognizer(perImage: ["認識テキストA", "認識テキストB"])
        let result = try await chapters(url, recognizer: stub)
        XCTAssertEqual(result.map(\.text), ["認識テキストA", "認識テキストB"])
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertEqual(stub.imageCount, 2)
    }

    func testTextLayerPageDoesNotInvokeRecognizer() async throws {
        let url = Fixture.pdf(pages: ["Real text layer"])
        let stub = StubRecognizer(perImage: ["SHOULD NOT APPEAR"])
        let result = try await chapters(url, recognizer: stub)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].text.contains("Real text layer"))
        XCTAssertEqual(stub.imageCount, 0)
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
        let stub = StubRecognizer(perImage: ["", "   "])
        do {
            _ = try await chapters(url, recognizer: stub)
            XCTFail("expected ocrFailed")
        } catch {
            XCTAssertEqual(error as? ImportError, .ocrFailed)
        }
    }

    func testOCRWindowingPreservesOrderAcrossWindows() async throws {
        let url = Fixture.imagePDF((0..<10).map { "page\($0)" })
        let counter = OCRCounter()
        let result = try await chapters(url, recognizer: counter)
        XCTAssertEqual(result.map(\.text), (0..<10).map { "P\($0)" })
        XCTAssertGreaterThanOrEqual(counter.calls, 2)
    }
}
