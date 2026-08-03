import Foundation
import PDFKit
import UIKit
import ReaderCore

struct PDFImporter: DocumentImporter {
    let url: URL
    var recognizer: PDFTextRecognizer? = nil
    var onProgress: ImportProgressHandler? = nil
    var onParsingProgress: ImportProgressHandler? = nil

    private static let ocrWindow = 8

    private enum Slot { case text(String); case ocr }

    func chapters() async throws -> [Chapter] {
        guard let doc = PDFDocument(url: url) else { throw ImportError.unreadable }
        if doc.isLocked { throw ImportError.passwordProtected }

        var slots: [Slot] = []
        var ocrPageIndices: [Int] = []
        var sawScannedPage = false
        onParsingProgress?(0, doc.pageCount)
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else {
                onParsingProgress?(i + 1, doc.pageCount)
                continue
            }
            let layer = page.string ?? ""
            if !layer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                slots.append(.text(layer))
            } else if recognizer != nil {
                slots.append(.ocr)
                ocrPageIndices.append(i)
            } else {
                sawScannedPage = true
            }
            onParsingProgress?(i + 1, doc.pageCount)
        }

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
            if recognizer != nil && !ocrPageIndices.isEmpty { throw ImportError.ocrFailed }
            if recognizer == nil && sawScannedPage { throw ImportError.ocrUnavailable }
            throw ImportError.empty
        }
        return chapters
    }

    func ocrCandidateCount() -> Int {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return 0 }
        var count = 0
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { count += 1 }
        }
        return count
    }

    private static let maxRasterPixels: CGFloat = 8_000_000

    static func render(_ page: PDFPage?, dpi: CGFloat = 200) -> CGImage {
        let bounds = page?.bounds(for: .mediaBox) ?? .zero
        guard let page, bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite else { return blankPixel }
        let scale = min(dpi / 72.0, (maxRasterPixels / (bounds.width * bounds.height)).squareRoot())
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width >= 1, size.height >= 1 else { return blankPixel }
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
