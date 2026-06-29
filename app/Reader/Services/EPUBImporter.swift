import Foundation
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

    func chapters() async throws -> [Chapter] {
        guard let archive = Archive(url: url, accessMode: .read) else { throw ImportError.unreadable }

        let opfPath = try locateOPF(in: archive)
        let opf = try OPF.parse(data(at: opfPath, in: archive))
        let opfDir = (opfPath as NSString).deletingLastPathComponent

        var chapters: [Chapter] = []
        for idref in opf.spine {
            guard let href = opf.manifest[idref] else { continue }
            let path = resolve(href, relativeTo: opfDir)
            guard let xhtml = try? data(at: path, in: archive) else { continue }
            let text = HTMLText.extract(xhtml)
            if !text.isEmpty { chapters.append(Chapter(title: nil, text: text)) }
        }
        guard !chapters.isEmpty else { throw ImportError.empty }
        return chapters
    }

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
