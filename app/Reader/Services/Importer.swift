import Foundation
import ReaderCore

/// Format-local parsing progress. The app keeps this deliberately separate from
/// OCR progress: parsing can be local/cheap while OCR is a paid network phase,
/// and the Library chrome labels them differently.
typealias ImportProgressHandler = @Sendable (_ completed: Int, _ total: Int) -> Void

/// Why an import failed — surfaced to the user as a short message.
enum ImportError: LocalizedError, Equatable {
    case unsupported
    case unreadable
    case empty
    case ocrFailed
    case ocrUnavailable
    case passwordProtected

    var errorDescription: String? {
        switch self {
        case .unsupported:       return L10n.importUnsupported
        case .unreadable:        return L10n.importUnreadable
        case .empty:             return L10n.importEmpty
        case .ocrFailed:         return L10n.importOCRFailed
        case .ocrUnavailable:    return L10n.importOCRUnavailable
        case .passwordProtected: return L10n.importPasswordProtected
        }
    }
}

/// The single ingestion entry point the "+" flow calls: picks the right
/// `DocumentImporter` for a file by extension and assembles a `Document` from the
/// chapters it yields. Title defaults to the file's display name. NFKC is NOT
/// applied here — it happens once downstream at the tokenize/TTS boundary, so
/// every ingestion path shares one normalization (see `DocumentImporter`).
enum Importer {
    static let supportedExtensions = ["epub", "pdf", "txt", "text", "md", "markdown"]

    /// Pick the importer for `url` by extension. `ocr`/`onProgress` drive the OCR
    /// fallback on the two formats that can be image-only: PDF (pages with no text
    /// layer) and EPUB (image-only spine items). Born-digital pages / extractable text
    /// bypass OCR; the text path and unsupported types ignore them.
    static func importer(for url: URL,
                         ocr: PDFTextRecognizer? = nil,
                         onParsingProgress: ImportProgressHandler? = nil,
                         onProgress: ImportProgressHandler? = nil) -> DocumentImporter? {
        switch url.pathExtension.lowercased() {
        case "epub":
            return EPUBImporter(url: url, recognizer: ocr, onProgress: onProgress,
                                onParsingProgress: onParsingProgress)
        case "pdf":
            return PDFImporter(url: url, recognizer: ocr, onProgress: onProgress,
                               onParsingProgress: onParsingProgress)
        case "txt", "text", "":
            return TextImporter(url: url, onParsingProgress: onParsingProgress)
        case "md", "markdown":
            return TextImporter(url: url, stripMarkdown: true,
                                onParsingProgress: onParsingProgress)
        default:                return nil
        }
    }

    /// How many page images an OCR pass would send for `url` — pages with no text layer
    /// (scanned PDF) or image-only EPUB spine items; 0 for formats that never OCR or
    /// files that already have text. Cheap (no rasterization, no network); drives the
    /// subscriber "read N pages with AI?" confirm after a local text-extraction miss.
    static func ocrPageCount(for url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "epub": return EPUBImporter(url: url).ocrCandidateCount()
        case "pdf":  return PDFImporter(url: url).ocrCandidateCount()
        default:     return 0
        }
    }

    /// Import `url` into a `Document`, or throw an `ImportError`. Image-only pages (a
    /// scanned PDF, or an image-only EPUB spine item) are OCR'd with `ocr` when supplied;
    /// `onProgress` reports OCR page completion for a determinate import banner.
    static func document(from url: URL,
                         ocr: PDFTextRecognizer? = nil,
                         onParsingProgress: ImportProgressHandler? = nil,
                         onProgress: ImportProgressHandler? = nil) async throws -> Document {
        guard let importer = importer(for: url, ocr: ocr,
                                      onParsingProgress: onParsingProgress,
                                      onProgress: onProgress) else {
            throw ImportError.unsupported
        }
        let chapters = try await importer.chapters()
        // The split below is a second full pass the wrapper performs itself — on a
        // whole-novel .txt it is the slowest step of the import. Drop back to an
        // indeterminate signal so the bar doesn't sit at a false 100% through it.
        onParsingProgress?(0, 0)
        // Split any oversized chapter (a whole-novel .txt, a long EPUB spine item) into
        // renderable sub-chapters — the reader draws one CoreText surface per chapter
        // and a huge one renders blank / janks. Small chapters pass through unchanged.
        let bounded = chapters.flatMap { $0.splitToRenderable() }
        guard !bounded.isEmpty else { throw ImportError.empty }
        let title = url.deletingPathExtension().lastPathComponent
        return Document(title: title, author: nil, chapters: bounded)
    }
}
