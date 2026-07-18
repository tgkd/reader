import Foundation
import ReaderCore

/// Imports a plain-text file as a single chapter. The encoding is sniffed
/// (UTF-8 → Shift-JIS → EUC-JP) by `JapaneseTextDecoder`; the chunker splits the
/// text for synthesis later, so the whole file is one chapter here. Markdown
/// files take the same path with `stripMarkdown` — the syntax markers would
/// otherwise be furigana'd and narrated.
struct TextImporter: DocumentImporter {
    let url: URL
    var stripMarkdown = false

    func chapters() async throws -> [Chapter] {
        let data = try Data(contentsOf: url)
        guard var text = JapaneseTextDecoder.decode(data) else {
            throw ImportError.unreadable
        }
        if stripMarkdown { text = MarkdownStrip.plainText(text) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.unreadable
        }
        return [Chapter(title: nil, text: text)]
    }
}

/// Reduces Markdown to readable prose: syntax markers are dropped, the text they
/// wrap is kept. Deliberately NOT a Markdown parser — just the common markers
/// that would otherwise be read aloud (headings, emphasis, links, code fences,
/// list bullets). Unknown constructs pass through untouched, which for a reading
/// app beats a strict parser failing on the messy files people actually have.
enum MarkdownStrip {
    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw
            // Whole-line constructs: fences and horizontal rules vanish entirely.
            if line.range(of: #"^\s*(```|~~~)"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^\s*([-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            // Leading markers: headings, blockquotes, list bullets / numbering.
            line = line.replacing(#"^#{1,6}\s+"#, with: "")
            line = line.replacing(#"^\s*(>\s?)+"#, with: "")
            line = line.replacing(#"^\s*([-*+]|\d{1,3}[.)])\s+"#, with: "")
            // Inline spans: keep the visible text, drop the wrapper.
            line = line.replacing(#"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")   // image → alt
            line = line.replacing(#"\[([^\]]+)\]\([^)]*\)"#, with: "$1")    // link → label
            line = line.replacing(#"`([^`]*)`"#, with: "$1")
            line = line.replacing(#"\*\*([^*]+)\*\*"#, with: "$1")
            line = line.replacing(#"__([^_]+)__"#, with: "$1")
            line = line.replacing(#"\*([^*\n]+)\*"#, with: "$1")
            line = line.replacing(#"_([^_\n]+)_"#, with: "$1")
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

private extension String {
    /// Regex replace with capture-group templates ($1), non-mutating.
    func replacing(_ pattern: String, with template: String) -> String {
        (try? NSRegularExpression(pattern: pattern))
            .map { $0.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self),
                                               withTemplate: template) }
            ?? self
    }
}
