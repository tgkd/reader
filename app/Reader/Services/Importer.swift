import Foundation
import ReaderCore

/// Why an import failed — surfaced to the user as a short message.
enum ImportError: LocalizedError {
    case unsupported
    case unreadable
    case empty

    var errorDescription: String? {
        switch self {
        case .unsupported: return L10n.importUnsupported
        case .unreadable:  return L10n.importUnreadable
        case .empty:       return L10n.importEmpty
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

    static func importer(for url: URL) -> DocumentImporter? {
        switch url.pathExtension.lowercased() {
        case "epub":            return EPUBImporter(url: url)
        case "pdf":             return PDFImporter(url: url)
        case "txt", "text", "": return TextImporter(url: url)
        default:                return nil
        }
    }

    /// Import `url` into a `Document`, or throw an `ImportError`.
    static func document(from url: URL) throws -> Document {
        guard let importer = importer(for: url) else { throw ImportError.unsupported }
        let chapters = try importer.chapters()
        guard !chapters.isEmpty else { throw ImportError.empty }
        let title = url.deletingPathExtension().lastPathComponent
        return Document(title: title, author: nil, chapters: chapters)
    }
}
