import Foundation
import ReaderCore

struct TextImporter: DocumentImporter {
    let url: URL
    var stripMarkdown = false
    var onParsingProgress: ImportProgressHandler? = nil

    func chapters() async throws -> [Chapter] {
        onParsingProgress?(0, 1)
        let data = try Data(contentsOf: url)
        guard var text = JapaneseTextDecoder.decode(data) else {
            throw ImportError.unreadable
        }
        if stripMarkdown { text = MarkdownStrip.plainText(text) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.unreadable
        }
        onParsingProgress?(1, 1)
        return [Chapter(title: nil, text: text)]
    }
}

enum MarkdownStrip {
    static func plainText(_ markdown: String) -> String {
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            var line = raw
            if line.range(of: #"^\s*(```|~~~)"#, options: .regularExpression) != nil { continue }
            if line.range(of: #"^\s*([-*_]\s*){3,}$"#, options: .regularExpression) != nil { continue }
            line = line.replacing(#"^#{1,6}\s+"#, with: "")
            line = line.replacing(#"^\s*(>\s?)+"#, with: "")
            line = line.replacing(#"^\s*([-*+]|\d{1,3}[.)])\s+"#, with: "")
            line = line.replacing(#"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")
            line = line.replacing(#"\[([^\]]+)\]\([^)]*\)"#, with: "$1")
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
    func replacing(_ pattern: String, with template: String) -> String {
        (try? NSRegularExpression(pattern: pattern))
            .map { $0.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self),
                                               withTemplate: template) }
            ?? self
    }
}
