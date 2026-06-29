import Foundation
import ReaderCore

/// Why an import failed — surfaced to the user as a short message.
enum ImportError: LocalizedError {
    case unsupported
    case unreadable
    case empty
    case ocrFailed

    var errorDescription: String? {
        switch self {
        case .unsupported: return L10n.importUnsupported
        case .unreadable:  return L10n.importUnreadable
        case .empty:       return L10n.importEmpty
        case .ocrFailed:   return L10n.importOCRFailed
        }
    }
}

/// The single ingestion entry point the "+" flow calls: picks the right
/// `DocumentImporter` for a file by extension and assembles a `Document` from the
/// chapters it yields. Title defaults to the file's display name. NFKC is NOT
/// applied here — it happens once downstream at the tokenize/TTS boundary, so
/// every ingestion path shares one normalization (see `DocumentImporter`).
enum Importer {
    static let supportedExtensions = ["epub", "pdf", "txt", "text"]

    /// Pick the importer for `url` by extension. `ocr`/`onProgress` are only used by
    /// the PDF path (text-layer pages bypass OCR; scanned pages are recognized);
    /// every other format ignores them.
    static func importer(for url: URL,
                         ocr: PDFTextRecognizer? = nil,
                         onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil) -> DocumentImporter? {
        switch url.pathExtension.lowercased() {
        case "epub":            return EPUBImporter(url: url)
        case "pdf":             return PDFImporter(url: url, recognizer: ocr, onProgress: onProgress)
        case "txt", "text", "": return TextImporter(url: url)
        default:                return nil
        }
    }

    /// Import `url` into a `Document`, or throw an `ImportError`. A PDF with no text
    /// layer is OCR'd with `ocr` (when supplied); `onProgress` reports OCR page
    /// completion for a determinate import banner.
    static func document(from url: URL,
                         ocr: PDFTextRecognizer? = nil,
                         onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil) async throws -> Document {
        guard let importer = importer(for: url, ocr: ocr, onProgress: onProgress) else { throw ImportError.unsupported }
        let chapters = try await importer.chapters()
        guard !chapters.isEmpty else { throw ImportError.empty }
        let title = url.deletingPathExtension().lastPathComponent
        return Document(title: title, author: nil, chapters: chapters)
    }
}
