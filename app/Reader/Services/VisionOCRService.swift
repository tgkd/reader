import Vision
import CoreGraphics

/// On-device OCR via the Vision framework — the DEFAULT recognizer. Free, offline,
/// and private (page images never leave the device). Recognizes Japanese with
/// `VNRecognizeTextRequest` (revision 3 added ja in iOS 16; the app targets iOS 17)
/// and reassembles observations into reading order with `ReadingOrder`.
///
/// Pages are recognized with bounded concurrency (full-res page bitmaps are large),
/// mirroring `ChunkingTTSService`'s window. Vertical (縦書き) quality is weak — that
/// is precisely what the Worker enhanced path exists to improve.
final class VisionOCRService: PDFTextRecognizer {
    private let maxConcurrent: Int

    init(maxConcurrent: Int = 2) {
        self.maxConcurrent = max(1, maxConcurrent)
    }

    func recognize(_ images: [CGImage],
                   progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) async throws -> [String] {
        guard !images.isEmpty else { return [] }
        var results = [String](repeating: "", count: images.count)
        var completed = 0

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var dispatched = 0
            func dispatchNext() {
                guard dispatched < images.count else { return }
                let i = dispatched
                let image = images[i]
                dispatched += 1
                group.addTask { (i, try Self.recognizePage(image)) }
            }
            for _ in 0..<min(maxConcurrent, images.count) { dispatchNext() }
            while let (i, text) = try await group.next() {
                results[i] = text
                completed += 1
                progress?(completed, images.count)
                dispatchNext()
            }
        }
        return results
    }

    /// Recognize one page image (blocking — `VNImageRequestHandler.perform` is
    /// synchronous; this runs inside the off-main task group).
    private static func recognizePage(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
            for: .accurate, revision: VNRecognizeTextRequestRevision3)) ?? []
        request.recognitionLanguages = supported.contains("ja") ? ["ja"] : ["ja", "en"]

        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])

        let boxes: [(text: String, box: CGRect)] = (request.results ?? []).compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string else { return nil }
            return (s, obs.boundingBox)   // normalized, origin bottom-left
        }
        return ReadingOrder.assemble(boxes)
    }
}
