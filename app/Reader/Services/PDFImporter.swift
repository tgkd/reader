import Foundation
import PDFKit
import ReaderCore

/// Imports a PDF via PDFKit, one chapter per page of extracted text (blank pages
/// skipped). Page text extraction is best-effort — complex multi-column or scanned
/// layouts won't yield clean reading order — but for reflowable/text PDFs it's the
/// spoken content. A page is one chapter so the reader can move through a long PDF
/// without synthesizing the whole thing at once.
struct PDFImporter: DocumentImporter {
    let url: URL

    func chapters() throws -> [Chapter] {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }

        var chapters: [Chapter] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chapters.append(Chapter(title: nil, text: text))
            }
        }
        guard !chapters.isEmpty else { throw ImportError.empty }
        return chapters
    }
}
