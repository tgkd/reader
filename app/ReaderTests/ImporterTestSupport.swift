import Foundation
import UIKit
import ZIPFoundation

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
    static func epub(manifest: [EPUBItem], spine: [SpineRef],
                     opfDir: String = "OEBPS", containerXML: String? = nil) throws -> URL {
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
}
