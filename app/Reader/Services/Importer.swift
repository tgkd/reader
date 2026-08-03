import Foundation
import ReaderCore

typealias ImportProgressHandler = @Sendable (_ completed: Int, _ total: Int) -> Void

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

enum Importer {
    static let supportedExtensions = ["epub", "pdf", "txt", "text", "md", "markdown"]

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

    static func ocrPageCount(for url: URL) -> Int {
        switch url.pathExtension.lowercased() {
        case "epub": return EPUBImporter(url: url).ocrCandidateCount()
        case "pdf":  return PDFImporter(url: url).ocrCandidateCount()
        default:     return 0
        }
    }

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
        onParsingProgress?(0, 0)
        let bounded = chapters.flatMap { $0.splitToRenderable() }
        guard !bounded.isEmpty else { throw ImportError.empty }
        let title = url.deletingPathExtension().lastPathComponent
        return Document(title: title, author: nil, chapters: bounded)
    }
}
