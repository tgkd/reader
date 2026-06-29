import CoreGraphics

/// Tries `primary` (the Worker enhanced OCR) and, on ANY error — network, a 429
/// storm, or the subscription backstop — transparently re-runs the whole batch
/// through `fallback` (on-device Vision). This guarantees an import never fails
/// because of the network: the worst case silently degrades to the free engine.
/// Mirrors `FallbackTTSService`.
final class FallbackOCRService: PDFTextRecognizer {
    private let primary: PDFTextRecognizer
    private let fallback: PDFTextRecognizer

    init(primary: PDFTextRecognizer, fallback: PDFTextRecognizer) {
        self.primary = primary
        self.fallback = fallback
    }

    func recognize(_ images: [CGImage],
                   progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) async throws -> [String] {
        do { return try await primary.recognize(images, progress: progress) }
        catch { return try await fallback.recognize(images, progress: progress) }
    }
}
