import CoreGraphics

/// Recovers Unicode text from page images when a PDF page has no text layer
/// (scanned / image-only PDFs, where `PDFPage.string` is empty). Two impls:
/// on-device `VisionOCRService` (the default — free, offline, private) and the
/// network `WorkerOCRService` (subscription-gated, opt-in enhanced quality).
///
/// The contract takes pre-rendered `CGImage`s (not `PDFPage`/`PDFDocument`) so the
/// engines stay free of PDFKit and are testable from any rasterized source, and a
/// whole BATCH so an engine can own its own concurrency window + backoff and report
/// progress at page granularity. Results are one string per input image, in order.
protocol PDFTextRecognizer: Sendable {
    /// Recognize text for each image, returning one string per image IN ORDER.
    /// `progress(completed, total)` fires as pages finish (may be off the main actor).
    func recognize(_ images: [CGImage],
                   progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) async throws -> [String]
}
