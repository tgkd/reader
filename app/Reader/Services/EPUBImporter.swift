import Foundation
import UIKit
import ZIPFoundation
import ReaderCore

/// Imports an EPUB. EPUB is a ZIP of XHTML documents; reading order comes from the
/// OPF `<spine>` — never the `<manifest>`, which is an unordered id→href map. The
/// flow: unzip → read `META-INF/container.xml` for the OPF path → parse the OPF
/// manifest + spine → for each spine item, strip its XHTML to plain text → one
/// chapter per non-empty spine document. Tags/entities are stripped tolerantly
/// (real EPUB XHTML isn't strict XML — `&nbsp;` etc.), so body text uses a
/// regex strip while the strict container/OPF use `XMLParser`.
struct EPUBImporter: DocumentImporter {
    let url: URL
    /// OCR engine for image-only spine items — fixed-layout / scanned EPUBs whose
    /// page text is baked into an image (`<img>` / SVG `<image>`), where tag-stripping
    /// recovers nothing. `nil` for non-subscribers: such a book then yields no chapters
    /// and throws `.empty`, exactly as before (OCR is a Membership feature). Mirrors
    /// `PDFImporter`; reuses the same `WorkerOCRService` (the Worker's `/pdf/ocr`).
    var recognizer: PDFTextRecognizer? = nil
    /// Reports OCR image completion (`completed`, `total`) for a determinate banner.
    var onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil

    /// How many page images to decode + recognize at once. Fixed-layout EPUB images
    /// can be large, so a whole image-only book is never decoded at once — windows
    /// bound peak memory (mirrors `PDFImporter.ocrWindow`).
    private static let ocrWindow = 8

    func chapters() async throws -> [Chapter] {
        guard let archive = Archive(url: url, accessMode: .read) else { throw ImportError.unreadable }
        let slots = try classify(archive)

        // OCR every image-only spine item's images, in order — but only when a
        // recognizer is present. Non-subscribers skip them, so an image-only book
        // stays chapter-less and falls through to `.empty` below (unchanged behavior).
        let imagePaths: [String] = recognizer == nil ? [] : slots.flatMap { slot -> [String] in
            if case .images(let p) = slot { return p }
            return []
        }
        var recognized: [String] = []
        if let recognizer, !imagePaths.isEmpty {
            recognized = try await recognize(imagePaths, in: archive, using: recognizer)
        }

        var chapters: [Chapter] = []
        var ocrCursor = 0
        for slot in slots {
            switch slot {
            case .text(let text):
                chapters.append(Chapter(title: nil, text: text))
            case .images(let images):
                guard recognizer != nil else { continue }   // non-subscriber: no OCR
                let text = recognized[ocrCursor..<ocrCursor + images.count]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ocrCursor += images.count
                if !text.isEmpty { chapters.append(Chapter(title: nil, text: text)) }
            }
        }

        guard !chapters.isEmpty else {
            // OCR ran but recovered nothing → ocrFailed; otherwise there was no readable
            // text at all (image-only book without a recognizer, or a genuinely empty one).
            if recognizer != nil && !imagePaths.isEmpty { throw ImportError.ocrFailed }
            throw ImportError.empty
        }
        return chapters
    }

    /// Number of page images an OCR pass would send for this EPUB (0 if every spine
    /// item already has extractable text). Cheap: classifies the spine without decoding
    /// images or hitting the network. Drives the import confirm prompt.
    func ocrCandidateCount() -> Int {
        guard let archive = Archive(url: url, accessMode: .read),
              let slots = try? classify(archive) else { return 0 }
        return slots.reduce(0) { acc, slot in
            if case .images(let p) = slot { return acc + p.count } else { return acc }
        }
    }

    // MARK: - Classification

    /// A spine item's content: its extracted text, or the archive paths of the images
    /// that stand in for its (image-only) text.
    private enum Slot { case text(String); case images([String]) }

    /// Walk the spine once: each item becomes `.text` (extractable text) or, when it has
    /// none but references images, `.images` (archive paths to OCR). Items with neither
    /// are dropped — matching the prior empty-body skip.
    private func classify(_ archive: Archive) throws -> [Slot] {
        let opfPath = try locateOPF(in: archive)
        let opf = try OPF.parse(data(at: opfPath, in: archive))
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        var slots: [Slot] = []
        for idref in opf.spine {
            guard let href = opf.manifest[idref] else { continue }
            let path = resolve(href, relativeTo: opfDir)
            guard let xhtml = try? data(at: path, in: archive) else { continue }
            let text = HTMLText.extract(xhtml)
            if !text.isEmpty { slots.append(.text(text)); continue }
            // No text — fold in any referenced images that actually exist in the archive,
            // resolved against THIS document's directory (not the OPF's).
            let itemDir = (path as NSString).deletingLastPathComponent
            let images = HTMLText.imageRefs(xhtml)
                .map { resolve($0, relativeTo: itemDir) }
                .filter { entry(for: $0, in: archive) != nil }
            if !images.isEmpty { slots.append(.images(images)) }
        }
        return slots
    }

    // MARK: - OCR

    /// Recognize `imagePaths` (archive entries) through `recognizer` in bounded windows,
    /// one string per path IN ORDER. Each window decodes its images, hands the batch to
    /// the recognizer, then releases them before the next (bounded memory); progress is
    /// reported cumulatively across windows.
    private func recognize(_ imagePaths: [String], in archive: Archive,
                           using recognizer: PDFTextRecognizer) async throws -> [String] {
        let total = imagePaths.count
        var out: [String] = []
        var base = 0
        for start in stride(from: 0, to: total, by: Self.ocrWindow) {
            let window = imagePaths[start..<min(start + Self.ocrWindow, total)]
            let images = window.map { Self.decode(try? data(at: $0, in: archive)) }
            let offset = base
            let texts = try await recognizer.recognize(images) { done, _ in
                onProgress?(offset + done, total)
            }
            out.append(contentsOf: texts)
            base += window.count
        }
        return out
    }

    /// Decode image bytes to a `CGImage`, or a 1×1 white pixel for missing/undecodable
    /// data — so results stay 1:1 with the image list (a dropped image would misalign
    /// every later chapter).
    private static func decode(_ data: Data?) -> CGImage {
        guard let data, let cg = UIImage(data: data)?.cgImage else { return blankPixel }
        return cg
    }

    private static let blankPixel: CGImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { ctx in
            UIColor.white.set(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.cgImage!
    }()

    // MARK: - Archive access

    private func data(at path: String, in archive: Archive) throws -> Data {
        guard let entry = entry(for: path, in: archive) else { throw ImportError.unreadable }
        var out = Data()
        _ = try archive.extract(entry) { out.append($0) }
        return out
    }

    /// Resolve an entry by path, tolerating percent-encoding and case differences.
    private func entry(for path: String, in archive: Archive) -> Entry? {
        if let e = archive[path] { return e }
        let decoded = path.removingPercentEncoding ?? path
        if let e = archive[decoded] { return e }
        return archive.first { $0.path.caseInsensitiveCompare(decoded) == .orderedSame }
    }

    private func locateOPF(in archive: Archive) throws -> String {
        let containerData = try data(at: "META-INF/container.xml", in: archive)
        guard let path = ContainerParser.rootfilePath(containerData) else { throw ImportError.unreadable }
        return path
    }

    /// Resolve a manifest href (relative to the OPF's directory), collapsing `..`.
    private func resolve(_ href: String, relativeTo dir: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let base = dir.isEmpty ? decoded : "\(dir)/\(decoded)"
        var stack: [String] = []
        for part in base.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." { _ = stack.popLast() }
            else if part == "." { continue }
            else { stack.append(String(part)) }
        }
        return stack.joined(separator: "/")
    }
}

// MARK: - container.xml

/// Pulls the first `<rootfile full-path="…">` (the OPF location) out of
/// `META-INF/container.xml`. Strict XML, so `XMLParser` is exact here.
private final class ContainerParser: NSObject, XMLParserDelegate {
    private var path: String?

    static func rootfilePath(_ data: Data) -> String? {
        let p = ContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.path
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        guard path == nil, elementName.localName == "rootfile" else { return }
        path = attributes["full-path"]
    }
}

// MARK: - OPF (manifest + spine)

private struct OPF {
    let manifest: [String: String]   // id → href
    let spine: [String]              // idrefs, in reading order

    static func parse(_ data: Data) throws -> OPF {
        let p = OPFParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() else { throw ImportError.unreadable }
        guard !p.spine.isEmpty else { throw ImportError.empty }
        return OPF(manifest: p.manifest, spine: p.spine)
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName.localName {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] { manifest[id] = href }
        case "itemref":
            // Skip linear="no" auxiliary content (footnotes, cover, copyright) —
            // not part of the primary flow a sequential reader narrates.
            if let idref = attributes["idref"], attributes["linear"]?.lowercased() != "no" {
                spine.append(idref)
            }
        default:
            break
        }
    }
}

private extension String {
    /// Local name of a possibly-namespaced XML element (`opf:item` → `item`).
    var localName: String { String(split(separator: ":").last ?? Substring(self)).lowercased() }
}

// MARK: - XHTML → plain text

/// Strips XHTML to readable plain text: isolates `<body>` (so `<head>/<title>`
/// never leaks into the chapter), block-level tags become newlines, all other
/// tags are removed, and HTML entities are decoded in one left-to-right pass.
/// Regex-based so it tolerates the not-quite-XML XHTML found in real EPUBs.
private enum HTMLText {
    static func extract(_ data: Data) -> String {
        // EPUB content is UTF-8/UTF-16 per spec; sniff (BOM-aware) and skip a file
        // we genuinely can't decode rather than emitting Latin-1 mojibake.
        guard var s = JapaneseTextDecoder.decode(data) else { return "" }

        // Isolate the body so head/title metadata never bleeds into the text.
        if let body = s.range(of: "(?is)<body[^>]*>.*</body>", options: .regularExpression) {
            s = String(s[body])
        }
        // Drop script/style blocks (case-insensitive).
        s = s.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ",
                                   options: .regularExpression)
        // Block-level boundaries → newline.
        s = s.replacingOccurrences(of: "(?i)<\\s*(br|/p|/div|/h[1-6]|/li|/tr)\\s*/?>", with: "\n",
                                   options: .regularExpression)
        // Remaining tags → removed.
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        // Tidy whitespace: collapse spaces, cap blank-line runs.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Image references inside `<img>` and SVG `<image>` tags, in document order — the
    /// `src` / `xlink:href` / `href` URL of each. Used by the OCR fallback to recover an
    /// image-only (fixed-layout / scanned) spine item. Inline `data:` URIs are skipped
    /// (they aren't archive entries); each tag yields its first URL-bearing attribute.
    static func imageRefs(_ data: Data) -> [String] {
        guard let s = JapaneseTextDecoder.decode(data),
              let tagRE = try? NSRegularExpression(pattern: "(?is)<(?:img|image)\\b[^>]*>"),
              let attrRE = try? NSRegularExpression(
                pattern: "(?is)(?:src|xlink:href|href)\\s*=\\s*[\"']([^\"']*)[\"']") else {
            return []
        }
        let ns = s as NSString
        var refs: [String] = []
        tagRE.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let tag = ns.substring(with: m.range)
            let tns = tag as NSString
            guard let am = attrRE.firstMatch(in: tag, range: NSRange(location: 0, length: tns.length)) else { return }
            let ref = tns.substring(with: am.range(at: 1))
            if !ref.isEmpty, !ref.lowercased().hasPrefix("data:") { refs.append(ref) }
        }
        return refs
    }

    /// Decode numeric (`&#38;` / `&#x26;`) and named entities in a single pass, so
    /// a decoded `&` is never rescanned (no `&amp;amp;` / `&#38;amp;` double-decode).
    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&"),
              let re = try? NSRegularExpression(pattern: "&(#x[0-9A-Fa-f]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);") else {
            return s
        }
        let ns = s as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let token = ns.substring(with: m.range(at: 1))
            result += decodeToken(token) ?? ns.substring(with: m.range)  // leave unknown entities intact
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    private static func decodeToken(_ token: String) -> String? {
        if token.hasPrefix("#x") || token.hasPrefix("#X") {
            return UInt32(token.dropFirst(2), radix: 16).flatMap(scalarString)
        }
        if token.hasPrefix("#") {
            return UInt32(token.dropFirst(), radix: 10).flatMap(scalarString)
        }
        switch token.lowercased() {
        case "amp":  return "&"
        case "lt":   return "<"
        case "gt":   return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        default:     return nil
        }
    }

    private static func scalarString(_ v: UInt32) -> String? {
        Unicode.Scalar(v).map { String(Character($0)) }
    }
}
