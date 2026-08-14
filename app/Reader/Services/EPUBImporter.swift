import Foundation
import ImageIO
import UIKit
import ZIPFoundation
import ReaderCore

struct EPUBImporter: DocumentImporter {
    let url: URL
    var recognizer: PDFTextRecognizer? = nil
    var onProgress: ImportProgressHandler? = nil
    var onParsingProgress: ImportProgressHandler? = nil

    private static let ocrWindow = 8

    func chapters() async throws -> [Chapter] {
        guard let archive = Archive(url: url, accessMode: .read) else { throw ImportError.unreadable }
        let (slots, wasFlattened) = repairFlattenedKana(in: try classify(archive))

        let imagePaths: [String] = recognizer == nil ? [] : slots.flatMap { slot -> [String] in
            if case .images(_, let p) = slot { return p }
            return []
        }
        var recognized: [String] = []
        if let recognizer, !imagePaths.isEmpty {
            recognized = try await recognize(imagePaths, in: archive, using: recognizer)
        }

        let index = readingIndex(of: slots)

        var chapters: [Chapter] = []
        var ocrCursor = 0
        for slot in slots {
            switch slot {
            case .text(let title, let text, let readings, _):
                chapters.append(Chapter(title: title, text: text,
                                        sourceReadings: propagate(index, into: text, given: readings),
                                        isFlattenedSource: wasFlattened))
            case .images(let title, let images):
                guard recognizer != nil else { continue }
                let text = recognized[ocrCursor..<ocrCursor + images.count]
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                ocrCursor += images.count
                if !text.isEmpty { chapters.append(Chapter(title: title, text: text)) }
            }
        }

        guard !chapters.isEmpty else {
            let hasImageSlots = slots.contains { if case .images = $0 { return true }; return false }
            if recognizer != nil && !imagePaths.isEmpty { throw ImportError.ocrFailed }
            if recognizer == nil && hasImageSlots { throw ImportError.ocrUnavailable }
            throw ImportError.empty
        }
        return chapters
    }

    func metadata() async throws -> DocumentMetadata {
        guard let archive = Archive(url: url, accessMode: .read),
              let opfPath = try? locateOPF(in: archive),
              let bytes = try? data(at: opfPath, in: archive),
              let opf = try? OPF.parse(bytes) else { return DocumentMetadata() }
        return DocumentMetadata(title: opf.title, author: opf.author, writingMode: opf.writingMode)
    }

    func ocrCandidateCount() -> Int {
        guard let archive = Archive(url: url, accessMode: .read),
              let slots = try? classify(archive) else { return 0 }
        return slots.reduce(0) { acc, slot in
            if case .images(_, let p) = slot { return acc + p.count } else { return acc }
        }
    }

    private func repairFlattenedKana(in slots: [Slot]) -> (slots: [Slot], wasFlattened: Bool) {
        let all = slots.flatMap { slot -> [String] in
            if case .text(_, _, let readings, _) = slot { return readings.map(\.reading) }
            return []
        }
        guard KanaRepair.looksFlattened(all) else { return (slots, false) }

        func repaired(_ r: SourceReading) -> SourceReading {
            let restored = KanaRepair.restoreSmallKana(r.reading)
            return SourceReading(start: r.start, length: r.length, surface: r.surface,
                                 reading: restored,
                                 rawReading: restored == r.reading ? nil : r.reading,
                                 groupLength: r.groupLength)
        }

        let out = slots.map { slot -> Slot in
            guard case .text(let title, let text, let readings, let groups) = slot else { return slot }
            return .text(
                title: title,
                text: text,
                readings: readings.map(repaired),
                groups: groups.map { HTMLText.RubyGroup(pairs: $0.pairs.map(repaired)) })
        }
        return (out, true)
    }

    private func readingIndex(of slots: [Slot]) -> [String: [SourceReading]] {
        var byWord: [String: Set<String>] = [:]
        var split: [String: [SourceReading]] = [:]
        for case .text(_, _, _, let groups) in slots {
            for g in groups where !g.surface.isEmpty && !g.reading.isEmpty {
                byWord[g.surface, default: []].insert(g.reading)
                let base = g.pairs.first?.start ?? 0
                split[g.surface] = g.pairs.map {
                    SourceReading(start: $0.start - base, length: $0.length,
                                  surface: $0.surface, reading: $0.reading,
                                  rawReading: $0.rawReading, groupLength: $0.groupLength)
                }
            }
        }
        return split.filter { byWord[$0.key]?.count == 1 && $0.key.count > 1 }
    }

    private func spellings(of word: String) -> [String] {
        let bare = VariationSelector.stripped(word)
        return bare == word ? [word] : [word, bare]
    }

    private func propagate(_ index: [String: [SourceReading]],
                           into text: String,
                           given existing: [SourceReading]) -> [SourceReading] {
        guard !index.isEmpty else { return existing }
        var out = existing
        var taken = existing.map { $0.start..<$0.end }
        let chars = Array(text)

        let ordered = index.sorted {
            $0.key.count != $1.key.count ? $0.key.count > $1.key.count : $0.key < $1.key
        }
        for (word, pairs) in ordered {
            for spelling in spellings(of: word) {
                var from = text.startIndex
                while let r = text.range(of: spelling, range: from..<text.endIndex) {
                    from = r.upperBound
                    let start = text.distance(from: text.startIndex, to: r.lowerBound)
                    let span = start..<(start + spelling.count)
                    guard !taken.contains(where: { $0.overlaps(span) }) else { continue }
                    taken.append(span)
                    for p in pairs {
                        let s = start + p.start
                        guard s + p.length <= chars.count else { continue }
                        let local = String(chars[s..<(s + p.length)])
                        guard VariationSelector.sameWord(local, p.surface) else { continue }
                        out.append(SourceReading(start: s, length: p.length,
                                                 surface: local, reading: p.reading,
                                                 rawReading: p.rawReading,
                                                 groupLength: p.groupLength))
                    }
                }
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private enum Slot {
        case text(title: String?, text: String, readings: [SourceReading], groups: [HTMLText.RubyGroup])
        case images(title: String?, paths: [String])
    }

    private func classify(_ archive: Archive) throws -> [Slot] {
        let opfPath = try locateOPF(in: archive)
        let opf = try OPF.parse(data(at: opfPath, in: archive))
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        let titles = tocTitles(in: archive, opf: opf, opfDir: opfDir)

        var slots: [Slot] = []
        onParsingProgress?(0, opf.spine.count)
        for (index, idref) in opf.spine.enumerated() {
            try Task.checkCancellation()
            defer { onParsingProgress?(index + 1, opf.spine.count) }
            guard let href = opf.manifest[idref] else { continue }
            let path = resolve(href, relativeTo: opfDir)
            guard let xhtml = try? data(at: path, in: archive) else { continue }
            let title = titles[path.lowercased()]
            let extracted = HTMLText.extractWithReadings(xhtml)
            if !extracted.text.isEmpty {
                slots.append(.text(title: title, text: extracted.text,
                                   readings: extracted.readings, groups: extracted.groups))
                continue
            }
            let itemDir = (path as NSString).deletingLastPathComponent
            let images = HTMLText.imageRefs(xhtml)
                .map { resolve($0, relativeTo: itemDir) }
                .filter { entry(for: $0, in: archive) != nil }
            if !images.isEmpty { slots.append(.images(title: title, paths: images)) }
        }
        return slots
    }

    private func tocTitles(in archive: Archive, opf: OPF, opfDir: String) -> [String: String] {
        var entries: [(href: String, title: String)] = []
        var tocDir = ""
        if let navHref = opf.navHref {
            let path = resolve(navHref, relativeTo: opfDir)
            if let bytes = try? data(at: path, in: archive) {
                entries = NavTOC.entries(bytes)
                tocDir = (path as NSString).deletingLastPathComponent
            }
        }
        if entries.isEmpty, let ncxHref = opf.ncxHref {
            let path = resolve(ncxHref, relativeTo: opfDir)
            if let bytes = try? data(at: path, in: archive) {
                entries = NCXParser.entries(bytes)
                tocDir = (path as NSString).deletingLastPathComponent
            }
        }
        var titles: [String: String] = [:]
        for (href, title) in entries {
            guard let file = href.split(separator: "#", maxSplits: 1).first.map(String.init),
                  !file.isEmpty else { continue }
            let key = resolve(file, relativeTo: tocDir).lowercased()
            if titles[key] == nil { titles[key] = title }
        }
        return titles
    }

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

    private static let maxImagePixelSize = 3000

    private static func decode(_ data: Data?) -> CGImage {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return blankPixel }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixelSize,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return blankPixel
        }
        return cg
    }

    private static let blankPixel: CGImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { ctx in
            UIColor.white.set(); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }.cgImage!
    }()

    private static let maxEntryBytes = 256 * 1024 * 1024

    private func data(at path: String, in archive: Archive) throws -> Data {
        guard let entry = entry(for: path, in: archive) else { throw ImportError.unreadable }
        guard entry.uncompressedSize <= UInt64(Self.maxEntryBytes) else { throw ImportError.unreadable }
        var out = Data()
        _ = try archive.extract(entry) { chunk in
            out.append(chunk)
            if out.count > Self.maxEntryBytes { throw ImportError.unreadable }
        }
        return out
    }

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

private final class ContainerParser: NSObject, XMLParserDelegate {
    private static let packageType = "application/oebps-package+xml"

    private var packagePath: String?
    private var anyPath: String?

    static func rootfilePath(_ data: Data) -> String? {
        let p = ContainerParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.packagePath ?? p.anyPath
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        guard elementName.localName == "rootfile",
              let path = attributes["full-path"], !path.isEmpty else { return }
        if anyPath == nil { anyPath = path }
        let type = attributes["media-type"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if packagePath == nil, type == Self.packageType { packagePath = path }
    }
}

private struct OPF {
    let manifest: [String: String]
    let spine: [String]
    let navHref: String?
    let ncxHref: String?
    let title: String?
    let author: String?
    let writingMode: WritingMode?

    static func parse(_ data: Data) throws -> OPF {
        let p = OPFParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() else { throw ImportError.unreadable }
        guard !p.spine.isEmpty else { throw ImportError.empty }
        return OPF(manifest: p.manifest, spine: p.spine,
                   navHref: p.navHref, ncxHref: p.ncxID.flatMap { p.manifest[$0] },
                   title: p.title, author: p.author, writingMode: p.writingMode)
    }
}

private final class OPFParser: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []
    var navHref: String?
    var ncxID: String?
    var title: String?
    var author: String?
    var writingMode: WritingMode?

    private var inMetadata = false
    private var capturing: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName.localName {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = href
                if navHref == nil,
                   attributes["properties"]?.lowercased().split(separator: " ").contains("nav") == true {
                    navHref = href
                }
            }
        case "itemref":
            if let idref = attributes["idref"], attributes["linear"]?.lowercased() != "no" {
                spine.append(idref)
            }
        case "spine":
            ncxID = attributes["toc"]
        case "metadata":
            inMetadata = true
        case "meta":
            guard writingMode == nil,
                  attributes["name"]?.lowercased() == "primary-writing-mode",
                  let content = attributes["content"]?.lowercased() else { break }
            if content.hasPrefix("vertical") { writingMode = .vertical }
            else if content.hasPrefix("horizontal") { writingMode = .horizontal }
        case "title" where inMetadata && title == nil,
             "creator" where inMetadata && author == nil:
            capturing = elementName.localName
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = elementName.localName
        if name == "metadata" {
            inMetadata = false
            capturing = nil
            return
        }
        guard let field = capturing, name == field else { return }
        let value = buffer
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            if field == "title" { title = value } else { author = value }
        }
        capturing = nil
        buffer = ""
    }
}

private enum NavTOC {
    static func entries(_ data: Data) -> [(href: String, title: String)] {
        guard let s = JapaneseTextDecoder.decode(data) else { return [] }
        let block = s.range(of: "(?is)<nav\\b[^>]*epub:type\\s*=\\s*[\"'][^\"']*\\btoc\\b[^\"']*[\"'][^>]*>.*?</nav>",
                            options: .regularExpression)
            ?? s.range(of: "(?is)<nav\\b[^>]*>.*?</nav>", options: .regularExpression)
        guard let block,
              let re = try? NSRegularExpression(
                pattern: "(?is)<a\\b[^>]*href\\s*=\\s*[\"']([^\"']*)[\"'][^>]*>(.*?)</a>") else { return [] }
        let nav = String(s[block])
        let ns = nav as NSString
        var out: [(href: String, title: String)] = []
        re.enumerateMatches(in: nav, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let href = ns.substring(with: m.range(at: 1))
            let title = HTMLText.decodeEntities(
                ns.substring(with: m.range(at: 2))
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !href.isEmpty, !href.hasPrefix("#") else { return }
            out.append((href, title))
        }
        return out
    }
}

private final class NCXParser: NSObject, XMLParserDelegate {
    private var found: [(href: String, title: String)] = []
    private var inNavMap = false
    private var inNavLabel = false
    private var labelText = ""
    private var pendingTitle: String?

    static func entries(_ data: Data) -> [(href: String, title: String)] {
        let p = NCXParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        guard parser.parse() else { return [] }
        return p.found
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName.localName {
        case "navmap":
            inNavMap = true
        case "navlabel":
            if inNavMap { inNavLabel = true; labelText = "" }
        case "content":
            if inNavMap, let src = attributes["src"], !src.isEmpty, let title = pendingTitle {
                found.append((src, title))
                pendingTitle = nil
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inNavLabel { labelText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName.localName {
        case "navmap":
            inNavMap = false
        case "navlabel":
            inNavLabel = false
            let title = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
            if inNavMap, !title.isEmpty { pendingTitle = title }
        default:
            break
        }
    }
}

private extension String {
    var localName: String { String(split(separator: ":").last ?? Substring(self)).lowercased() }
}

private enum HTMLText {
    struct RubyGroup {
        let pairs: [SourceReading]
        var surface: String { pairs.map(\.surface).joined() }
        var reading: String { pairs.map(\.reading).joined() }
    }

    private static let rubyOpen: Character = "\u{0011}"
    private static let rubyClose: Character = "\u{0012}"
    private static let rubyGroupEnd: Character = "\u{0013}"

    static func extract(_ data: Data) -> String { extractWithReadings(data).text }

    static func extractWithReadings(_ data: Data)
        -> (text: String, readings: [SourceReading], groups: [RubyGroup]) {
        let (marked, readings) = strip(data, markingRuby: true)
        return unmarkRuby(marked, readings: readings)
    }

    private static func unmarkRuby(_ s: String, readings: [String])
        -> (text: String, readings: [SourceReading], groups: [RubyGroup]) {
        guard s.contains(rubyOpen) else { return (s, [], []) }
        var out = ""
        out.reserveCapacity(s.count)
        var found: [SourceReading] = []
        var groups: [RubyGroup] = []
        var groupStart = 0
        var baseStart: Int?
        var base = ""
        var next = 0
        for ch in s {
            switch ch {
            case rubyOpen:
                baseStart = out.count
                base = ""
            case rubyClose:
                defer { baseStart = nil; next += 1 }
                guard let start = baseStart, !base.isEmpty, next < readings.count else { continue }
                found.append(SourceReading(start: start, length: base.count,
                                           surface: base, reading: readings[next]))
            case rubyGroupEnd:
                if found.count > groupStart {
                    if found.count - groupStart > 1 {
                        let total = found[groupStart...].reduce(0) { $0 + $1.length }
                        for k in groupStart..<found.count {
                            found[k] = SourceReading(start: found[k].start, length: found[k].length,
                                                     surface: found[k].surface,
                                                     reading: found[k].reading,
                                                     groupLength: total)
                        }
                    }
                    groups.append(RubyGroup(pairs: Array(found[groupStart...])))
                    groupStart = found.count
                }
            default:
                if baseStart != nil { base.append(ch) }
                out.append(ch)
            }
        }
        return (out, found, groups)
    }

    private static func strip(_ data: Data, markingRuby: Bool) -> (String, [String]) {
        guard var s = JapaneseTextDecoder.decode(data) else { return ("", []) }
        s.removeAll { $0 == rubyOpen || $0 == rubyClose || $0 == rubyGroupEnd }

        if let body = s.range(of: "(?is)<body[^>]*>.*</body>", options: .regularExpression) {
            s = String(s[body])
        }
        s = s.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: " ",
                                   options: .regularExpression)
        var readings: [String] = []
        if markingRuby { (s, readings) = markRuby(s) }
        s = s.replacingOccurrences(of: "(?is)<(rt|rp)[^>]*>.*?</\\1>", with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<\\s*(br|/p|/div|/h[1-6]|/li|/tr)\\s*/?>", with: "\n",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return (s.trimmingCharacters(in: .whitespacesAndNewlines), readings)
    }

    private static func markRuby(_ input: String) -> (String, [String]) {
        guard input.range(of: "(?i)<ruby[\\s>]", options: .regularExpression) != nil else {
            return (input, [])
        }
        var readings: [String] = []
        var out = ""
        var rest = Substring(input)

        func plain(_ s: Substring) -> String {
            var t = String(s).replacingOccurrences(of: "(?is)<[^>]+>", with: "",
                                                   options: .regularExpression)
            t = decodeEntities(t)
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        while let open = rest.range(of: "(?i)\(openTag("ruby"))", options: .regularExpression) {
            guard let close = rest.range(of: "(?i)</ruby\\s*>", options: .regularExpression,
                                         range: open.upperBound..<rest.endIndex) else { break }
            out += rest[rest.startIndex..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound]
            rest = rest[close.upperBound...]

            let body = String(inner).replacingOccurrences(
                of: "(?is)\(openTag("rp")).*?</rp\\s*>", with: "", options: .regularExpression)

            var pairs = capturePairs(
                "(?is)\(openTag("rb"))(.*?)</rb\\s*>\\s*\(openTag("rt"))(.*?)</rt\\s*>", in: body)
            if pairs.isEmpty { pairs = groupedPairs(in: body) }
            if !pairs.isEmpty {
                var wrote = false
                for (base, reading) in pairs {
                    let b = plain(Substring(base)), r = plain(Substring(reading))
                    guard !b.isEmpty, !r.isEmpty else { out += b; continue }
                    out.append(rubyOpen); out += b; out.append(rubyClose)
                    readings.append(r)
                    wrote = true
                }
                if wrote { out.append(rubyGroupEnd) }
                continue
            }
            var scan = Substring(body)
            var sawPair = false
            var wrote = false
            while let rt = scan.range(of: "(?i)\(openTag("rt"))", options: .regularExpression),
                  let rtEnd = scan.range(of: "(?i)</rt\\s*>", options: .regularExpression,
                                         range: rt.upperBound..<scan.endIndex) {
                sawPair = true
                let b = plain(scan[scan.startIndex..<rt.lowerBound])
                let r = plain(scan[rt.upperBound..<rtEnd.lowerBound])
                scan = scan[rtEnd.upperBound...]
                guard !b.isEmpty, !r.isEmpty else { out += b; continue }
                out.append(rubyOpen); out += b; out.append(rubyClose)
                readings.append(r)
                wrote = true
            }
            if sawPair {
                if wrote { out.append(rubyGroupEnd) }
                out += plain(scan)
                continue
            }
            out += plain(Substring(body))
        }
        out += rest
        return (out, readings)
    }

    private static func openTag(_ name: String) -> String {
        "<\(name)\\b(?:\"[^\"]*\"|'[^']*'|[^>\"'])*>"
    }

    private static func groupedPairs(in body: String) -> [(String, String)] {
        let bases = capture("(?is)\(openTag("rb"))(.*?)</rb\\s*>", in: body)
        guard !bases.isEmpty else { return [] }
        let scope = body.range(of: "(?is)\(openTag("rtc")).*?</rtc\\s*>", options: .regularExpression)
            .map { String(body[$0]) } ?? body
        let annotations = capturePairs(
            "(?is)<rt\\b((?:\"[^\"]*\"|'[^']*'|[^>\"'])*)>(.*?)</rt\\s*>", in: scope)

        var pairs: [(String, String)] = []
        var next = 0
        for (attributes, reading) in annotations {
            let (limit, overflowed) = next.addingReportingOverflow(rbspan(attributes))
            guard !overflowed, limit <= bases.count else { return [] }
            pairs.append((bases[next..<limit].joined(), reading))
            next = limit
        }
        guard next == bases.count else { return [] }
        return pairs
    }

    private static func rbspan(_ attributes: String) -> Int {
        guard let re = try? NSRegularExpression(
            pattern: "([A-Za-z_:][-.A-Za-z0-9_:]*)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]*))")
        else { return 1 }
        let ns = attributes as NSString
        for m in re.matches(in: attributes, range: NSRange(location: 0, length: ns.length)) {
            guard ns.substring(with: m.range(at: 1)).lowercased() == "rbspan" else { continue }
            let value = (2...4).first { m.range(at: $0).location != NSNotFound }
                .map { ns.substring(with: m.range(at: $0)) } ?? ""
            let digits = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return 1 }
            return Int(digits).map { max(1, $0) } ?? Int.max
        }
        return 1
    }

    private static func capture(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges >= 2, m.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }

    private static func capturePairs(_ pattern: String, in s: String) -> [(String, String)] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges >= 3,
                  m.range(at: 1).location != NSNotFound,
                  m.range(at: 2).location != NSNotFound else { return nil }
            return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
        }
    }

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

    static func decodeEntities(_ s: String) -> String {
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
            result += decodeToken(token) ?? ns.substring(with: m.range)
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
        guard v > 0x1F || v == 0x09 || v == 0x0A || v == 0x0D else { return "" }
        return Unicode.Scalar(v).map { String(Character($0)) }
    }
}
