import CoreGraphics

protocol PDFTextRecognizer: Sendable {
    func recognize(_ images: [CGImage],
                   progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)?) async throws -> [String]
}
