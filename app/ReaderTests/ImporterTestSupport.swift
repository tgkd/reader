import Foundation
import UIKit
import PDFKit
import ZIPFoundation
@testable import Reader

struct ImportProgressSample: Equatable {
    let completed: Int
    let total: Int
}

final class ImportProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [ImportProgressSample] = []

    func record(_ completed: Int, _ total: Int) {
        lock.lock()
        samples.append(ImportProgressSample(completed: completed, total: total))
        lock.unlock()
    }

    var values: [ImportProgressSample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

enum Fixture {
    private static func uniqueURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderTests-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }

    @discardableResult
    static func write(_ data: Data, ext: String) -> URL {
        let url = uniqueURL(ext: ext)
        try! data.write(to: url)
        return url
    }

    static func renamed(_ url: URL, to name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try! FileManager.default.copyItem(at: url, to: dest)
        return dest
    }

    static func textFile(_ string: String, encoding: String.Encoding,
                         ext: String = "txt", bom: [UInt8] = []) -> URL {
        var data = Data(bom)
        data.append(string.data(using: encoding)!)
        return write(data, ext: ext)
    }

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

    static func lockedPDF() -> URL {
        let plain = PDFDocument(url: pdf(pages: ["Locked content"]))!
        let url = uniqueURL(ext: "pdf")
        plain.write(to: url, withOptions: [.userPasswordOption: "secret",
                                           .ownerPasswordOption: "secret"])
        return url
    }

    private static func textImage(_ text: String, size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(in: CGRect(origin: .zero, size: size).insetBy(dx: 48, dy: 60),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 44),
                                                     .foregroundColor: UIColor.black])
        }
    }

    struct EPUBItem {
        let id: String
        let href: String
        let content: String
        var properties: String? = nil
        var mediaType: String = "application/xhtml+xml"
    }

    struct SpineRef {
        let idref: String
        let linear: Bool
        init(_ idref: String, linear: Bool = true) { self.idref = idref; self.linear = linear }
    }

    static func xhtml(body: String, title: String = "HEAD_TITLE_DO_NOT_LEAK") -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(title)</title></head>\
        <body>\(body)</body></html>
        """
    }

    static func epub(manifest: [EPUBItem], spine: [SpineRef],
                     opfDir: String = "OEBPS", containerXML: String? = nil,
                     spineTOC: String? = nil,
                     extraFiles: [String: Data] = [:]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderTests-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

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

        let manifestXML = manifest.map {
            let props = $0.properties.map { " properties=\"\($0)\"" } ?? ""
            return "<item id=\"\($0.id)\" href=\"\($0.href)\" media-type=\"\($0.mediaType)\"\(props)/>"
        }.joined(separator: "\n")
        let spineXML = spine.map {
            "<itemref idref=\"\($0.idref)\"\($0.linear ? "" : " linear=\"no\"")/>"
        }.joined(separator: "\n")
        let opf = """
        <?xml version="1.0"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
          <manifest>\(manifestXML)</manifest>
          <spine\(spineTOC.map { " toc=\"\($0)\"" } ?? "")>\(spineXML)</spine>
        </package>
        """
        let opfURL = root.appendingPathComponent(opfPath)
        try FileManager.default.createDirectory(at: opfURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try opf.write(to: opfURL, atomically: true, encoding: .utf8)

        for item in manifest {
            let rel = opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
            let decoded = rel.removingPercentEncoding ?? rel
            let fileURL = root.appendingPathComponent(decoded)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try item.content.write(to: fileURL, atomically: true, encoding: .utf8)
        }

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

    static func navDoc(_ entries: [(href: String, title: String)]) -> String {
        let items = entries.map { "<li><a href=\"\($0.href)\">\($0.title)</a></li>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">\
        <head><title>TOC</title></head>\
        <body><nav epub:type="toc"><ol>\(items)</ol></nav></body></html>
        """
    }

    static func ncx(_ entries: [(src: String, title: String)]) -> String {
        let points = entries.enumerated().map { i, e in
            """
            <navPoint id="np\(i)" playOrder="\(i + 1)">\
            <navLabel><text>\(e.title)</text></navLabel>\
            <content src="\(e.src)"/></navPoint>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">\
        <head/><docTitle><text>DOC_TITLE_DO_NOT_LEAK</text></docTitle>\
        <navMap>\(points)</navMap></ncx>
        """
    }

    static func simpleEPUB(_ bodies: [String]) throws -> URL {
        let items = bodies.enumerated().map {
            EPUBItem(id: "c\($0.offset)", href: "c\($0.offset).xhtml",
                     content: xhtml(body: "<p>\($0.element)</p>"))
        }
        return try epub(manifest: items, spine: items.map { SpineRef($0.id) })
    }

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

    static func jpeg(_ label: String) -> Data {
        textImage(label, size: CGSize(width: 320, height: 480)).jpegData(compressionQuality: 0.8)!
    }
}

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
