import XCTest
import ReaderCore
@testable import Reader

/// Integration coverage for the on-device Vision path: an image-only PDF (no text
/// layer) is recovered through `PDFImporter` → `VisionOCRService`. Asserts the
/// PIPELINE (render → recognize → chapter), not Apple's recognition accuracy, so it
/// uses reliably-read Latin content. Japanese reading-order logic — the part we
/// wrote — is covered deterministically in `ReadingOrderTests`.
final class VisionOCRServiceTests: XCTestCase {

    func testEmptyImagesReturnsEmpty() async throws {
        let out = try await VisionOCRService().recognize([], progress: nil)
        XCTAssertEqual(out, [])
    }

    func testImageOnlyPDFIsRecoveredViaOCR() async throws {
        let url = Fixture.imagePDF(["READER OCR"])
        let result = try await PDFImporter(url: url, recognizer: VisionOCRService()).chapters()
        XCTAssertEqual(result.count, 1)
        let text = result[0].text.uppercased().replacingOccurrences(of: " ", with: "")
        // Latin is read reliably; tolerate minor errors by requiring either token.
        XCTAssertTrue(text.contains("READER") || text.contains("OCR"),
                      "OCR recovered: \(result[0].text)")
    }
}
