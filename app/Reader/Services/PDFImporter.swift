import Foundation
import PDFKit
import UIKit
import ReaderCore

/// Imports a PDF, one chapter per page. A page's text comes from PDFKit's text
/// layer (`PDFPage.string`) when present; pages with NO text layer (scanned /
/// image-only PDFs) are rasterized and handed to an injected `PDFTextRecognizer`
/// (the Worker's gated cloud OCR — see `WorkerOCRService`). Born-digital pages never
/// touch OCR — no cost, no network. A page is one chapter so the reader can move
/// through a long PDF without synthesizing the whole thing at once.
struct PDFImporter: DocumentImporter {
    let url: URL
    /// OCR engine for pages with no text layer. `nil` for non-subscribers — a scanned
    /// PDF then throws `.ocrUnavailable` (OCR is a Membership feature).
    var recognizer: PDFTextRecognizer? = nil
    /// Reports OCR page completion (`completed`, `total`) for a determinate banner.
    var onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil

    /// How many page bitmaps to hold + recognize at once. Full-res (200 DPI) page
    /// bitmaps are large (~15 MB each), so a whole 200-page scan is never rasterized
    /// at once — we render and recognize in windows to bound peak memory.
    private static let ocrWindow = 8

    /// A page's source: its text-layer string, or a placeholder for an OCR page
    /// (filled in order from the recognized results).
    private enum Slot { case text(String); case ocr }

    func chapters() async throws -> [Chapter] {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }

        // Pass 1 (cheap, no rasterization): classify each page as text-layer or OCR.
        var slots: [Slot] = []
        var ocrPageIndices: [Int] = []
        var sawScannedPage = false // a page with no text layer (would need OCR)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let layer = page.string ?? ""
            if !layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                slots.append(.text(layer))
            } else if recognizer != nil {
                slots.append(.ocr)
                ocrPageIndices.append(i)
            } else {
                sawScannedPage = true // no OCR engine (non-subscriber)
            }
        }

        // Pass 2: OCR in bounded-memory windows. Each window is rendered, recognized,
        // then released before the next; progress is reported cumulatively. Results
        // stay 1:1 with `ocrPageIndices` (render never drops a page — see `render`).
        var recognized: [String] = []
        if let recognizer, !ocrPageIndices.isEmpty {
            let total = ocrPageIndices.count
            var base = 0
            for start in stride(from: 0, to: total, by: Self.ocrWindow) {
                let pages = ocrPageIndices[start..<min(start + Self.ocrWindow, total)]
                let images = pages.map { Self.render(doc.page(at: $0)) }
                let offset = base
                let texts = try await recognizer.recognize(images) { done, _ in
                    onProgress?(offset + done, total)
                }
                recognized.append(contentsOf: texts)
                base += pages.count
            }
        }

        var chapters: [Chapter] = []
        var ocrCursor = 0
        for slot in slots {
            switch slot {
            case .text(let t):
                chapters.append(Chapter(title: nil, text: t))
            case .ocr:
                let text = recognized[ocrCursor]
                ocrCursor += 1
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    chapters.append(Chapter(title: nil, text: text))
                }
            }
        }

        guard !chapters.isEmpty else {
            // A scanned PDF with no recognizer (non-subscriber) → Membership prompt;
            // OCR ran but recovered nothing → ocrFailed; otherwise a genuinely blank file.
            if recognizer != nil && !ocrPageIndices.isEmpty { throw ImportError.ocrFailed }
            if recognizer == nil && sawScannedPage { throw ImportError.ocrUnavailable }
            throw ImportError.empty
        }
        return chapters
    }

    /// Rasterize a page for OCR. 200 DPI balances accuracy against memory
    /// (US-letter → ~1700×2200 px). White background so transparent scans don't OCR
    /// as noise. PDFKit's origin is bottom-left, so the context is flipped before
    /// drawing. Always returns an image (a 1×1 white fallback for a nil/zero-size
    /// page) so the OCR results stay 1:1 with the page list.
    static func render(_ page: PDFPage?, dpi: CGFloat = 200) -> CGImage {
        let bounds = page?.bounds(for: .mediaBox) ?? .zero
        guard let page, bounds.width > 0, bounds.height > 0 else { return blankPixel }
        let scale = dpi / 72.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: cg)
        }
        return image.cgImage ?? blankPixel
    }

    private static let blankPixel: CGImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { ctx in
            UIColor.white.set(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.cgImage!
    }()
}
