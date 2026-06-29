import CoreGraphics

/// Recovers Unicode text from page images when a PDF page has no text layer
/// (scanned / image-only PDFs, where `PDFPage.string` is empty). The one impl is the
/// network `WorkerOCRService` (the Worker's Gemini OCR via AI Gateway, subscription-
/// gated). On-device OCR was dropped — its quality wasn't good enough for a reader.
/// The protocol stays so `PDFImporter` is decoupled and tests can stub it.
///
/// The contract takes pre-rendered `CGImage`s (not `PDFPage`/`PDFDocument`) so the
/// engine stays free of PDFKit and is testable from any rasterized source, and a
/// whole BATCH so it can own its concurrency window + backoff and report progress at
/// page granularity. Results are one string per input image, in order.
protocol PDFTextRecognizer: Sendable {
    /// Recognize text for each image, returning one string per image IN ORDER.
    /// `progress(completed, total)` fires as pages finish (may be off the main actor).
    func recognize(_ images: [CGImage],
                   progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) async throws -> [String]
}
