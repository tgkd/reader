import Foundation
import UIKit
import ZIPFoundation
@testable import Reader

/// Runtime fixture generators for the importer tests. Nothing is committed as a
/// binary: EPUBs are zipped on the fly (so spine/manifest/linear variations are
/// trivial to express), PDFs are rendered with real selectable text, and text
/// files are written in the encoding under test.
enum Fixture {

    // MARK: - Temp files

    private static func uniqueURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderTests-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    /// Write raw bytes to a unique temp file with `ext`; returns the URL.
    @discardableResult
    static func write(_ data: Data, ext: String) -> URL {
        let url = uniqueURL(ext: ext)
        try! data.write(to: url)
        return url
    }

    /// Copy `url` to a file named exactly `name` (to exercise filename-derived
    /// titles). The unique token goes in a parent directory so the filename — and
    /// thus the derived title — is precisely `name`.
    static func renamed(_ url: URL, to name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try! FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    // MARK: - Text

    /// A text file in `encoding`, optionally prefixed with a byte-order mark.
    static func textFile(_ string: String, encoding: String.Encoding,
                         ext: String = "txt", bom: [UInt8] = []) -> URL {
        var data = Data(bom)
        data.append(string.data(using: encoding)!)
        return write(data, ext: ext)
    }

    // MARK: - PDF

    /// A PDF with one page per entry in `pages` (empty string → a genuinely blank
    /// page). Text is drawn as real glyphs so `PDFPage.string` extracts it.
    static func pdf(pages: [String]) -> URL {
        let url = uniqueURL(ext: "pdf")
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try! renderer.writePDF(to: url) { ctx in
            for text in pages {
                ctx.beginPage()
                guard !text.isEmpty else { continue }
                (text as NSString).draw(in: bounds.insetBy(dx: 48, dy: 48),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 28),
                                                         .foregroundColor: UIColor.black])
            }
        }
        return url
    }

    /// A PDF whose pages have NO text layer: each string is rasterized to an image
    /// and drawn as an image XObject, so `PDFPage.string` is empty — simulating a
    /// scanned / image-only PDF. Exercises the OCR fallback path. The rasterized
    /// text is legible (black on white, large) so a real recognizer can read it.
    static func imagePDF(_ pages: [String]) -> URL {
        let url = uniqueURL(ext: "pdf")
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        try! renderer.writePDF(to: url) { ctx in
            for text in pages {
                ctx.beginPage()
                guard !text.isEmpty else { continue }
                textImage(text, size: bounds.size).draw(in: bounds)
            }
        }
        return url
    }

    /// Rasterize `text` onto a white image (drawn into a PDF → no text layer).
    private static func textImage(_ text: String, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(in: CGRect(origin: .zero, size: size).insetBy(dx: 48, dy: 60),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 44),
                                                     .foregroundColor: UIColor.black])
        }
    }

    // MARK: - EPUB

    struct EPUBItem {
        let id: String
        let href: String      // relative to the OPF directory
        let content: String   // full XHTML document
    }

    struct SpineRef {
        let idref: String
        let linear: Bool
        init(_ idref: String, linear: Bool = true) { self.idref = idref; self.linear = linear }
    }

    /// Wrap body markup in a minimal XHTML document with a `<head><title>` (so tests
    /// can assert head metadata never leaks into the extracted chapter).
    static func xhtml(body: String, title: String = "HEAD_TITLE_DO_NOT_LEAK") -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head>\
        <body>\(body)</body></html>
        """
    }

    /// Build a valid EPUB (a ZIP) from a manifest + an explicit spine. The spine
    /// order is independent of manifest order, so reading-order tests are exact.
    /// `extraFiles` (href relative to the OPF dir → bytes) drops non-XHTML resources
    /// — e.g. the images an image-only spine item references — into the archive.
    static func epub(manifest: [EPUBItem], spine: [SpineRef],
                     opfDir: String = "OEBPS", containerXML: String? = nil,
                     extraFiles: [String: Data] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderTests-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // EPUB OCF: mimetype + META-INF/container.xml → OPF.
        try "application/epub+zip".write(to: root.appendingPathComponent("mimetype"),
                                         atomically: true, encoding: .utf8)
        let metaInf = root.appendingPathComponent("META-INF")
        try FileManager.default.createDirectory(at: metaInf, withIntermediateDirectories: true)

        let opfPath = opfDir.isEmpty ? "content.opf" : "\(opfDir)/content.opf"
        let container = containerXML ?? """
        <?xml version="1.0"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="\(opfPath)" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        try container.write(to: metaInf.appendingPathComponent("container.xml"),
                            atomically: true, encoding: .utf8)

        // OPF: manifest (id→href) + spine (ordered idrefs, optional linear="no").
        let manifestXML = manifest.map {
            "<item id=\"\($0.id)\" href=\"\($0.href)\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spineXML = spine.map {
            "<itemref idref=\"\($0.idref)\"\($0.linear ? "" : " linear=\"no\"")/>"
        }.joined(separator: "\n")
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>\(manifestXML)</manifest>
          <spine>\(spineXML)</spine>
        </package>
        """
        let opfURL = root.appendingPathComponent(opfPath)
        try FileManager.default.createDirectory(at: opfURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try opf.write(to: opfURL, atomically: true, encoding: .utf8)

        // Item documents, stored at the (percent-decoded) path the importer resolves.
        for item in manifest {
            let rel = opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
            let decoded = rel.removingPercentEncoding ?? rel
            let fileURL = root.appendingPathComponent(decoded)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try item.content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

        // Extra (binary) resources — images an image-only page points at.
        for (href, bytes) in extraFiles {
            let rel = opfDir.isEmpty ? href : "\(opfDir)/\(href)"
            let fileURL = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: fileURL)
        }

        let epubURL = uniqueURL(ext: "epub")
        try FileManager.default.zipItem(at: root, to: epubURL, shouldKeepParent: false)
        return epubURL
    }

    /// Convenience: chapters c0…cN in declared order, spine matching, plain `<p>` bodies.
    static func simpleEPUB(_ bodies: [String]) throws -> URL {
        let items = bodies.enumerated().map {
            EPUBItem(id: "c\($0.offset)", href: "c\($0.offset).xhtml",
                     content: xhtml(body: "<p>\($0.element)</p>"))
        }
        return try epub(manifest: items, spine: items.map { SpineRef($0.id) })
    }

    /// An EPUB whose spine pages have NO extractable text: each is a single `<img>`
    /// referencing a real JPEG stored in the archive (a fixed-layout / scanned book).
    /// Exercises the EPUB image→OCR fallback.
    static func imageEPUB(pages count: Int) throws -> URL {
        var manifest: [EPUBItem] = []
        var images: [String: Data] = [:]
        for i in 0..<count {
            let href = "images/p\(i).jpg"
            images[href] = jpeg("PAGE\(i)")
            manifest.append(EPUBItem(id: "p\(i)", href: "p\(i).xhtml",
                                     content: xhtml(body: "<p><img src=\"\(href)\" alt=\"\"/></p>")))
        }
        return try epub(manifest: manifest, spine: manifest.map { SpineRef($0.id) }, extraFiles: images)
    }

    /// A small, genuinely decodable JPEG (so `UIImage(data:)` succeeds). The pixels are
    /// irrelevant to the stub recognizers, which ignore image content.
    static func jpeg(_ label: String) -> Data {
        textImage(label, size: CGSize(width: 320, height: 480)).jpegData(compressionQuality: 0.8)!
    }
}

// MARK: - Shared OCR stubs

/// Canned recognizer for the importer tests: returns `perImage` text in order and
/// records how it was called.
final class StubRecognizer: PDFTextRecognizer, @unchecked Sendable {
    private let perImage: [String]
    private(set) var callCount = 0
    private(set) var imageCount = 0

    init(perImage: [String]) { self.perImage = perImage }

    func recognize(_ images: [CGImage],
                   progress: (@Sendable (Int, Int) -> Void)?) async throws -> [String] {
        callCount += 1
        imageCount += images.count
        return images.enumerated().map { i, _ in i < perImage.count ? perImage[i] : "" }
    }
}

/// Returns globally-incrementing "P{n}" per image and counts how many batched calls it
/// received — proves windowed processing preserves order across passes.
final class OCRCounter: PDFTextRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private var next = 0

    func recognize(_ images: [CGImage],
                   progress: (@Sendable (Int, Int) -> Void)?) async throws -> [String] {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return images.map { _ in defer { next += 1 }; return "P\(next)" }
    }
}
