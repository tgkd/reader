import Foundation

public struct SourceReading: Codable, Equatable, Sendable {
    public let start: Int
    public let length: Int
    public let surface: String
    public let reading: String

    public let rawReading: String?
    public let groupLength: Int?

    public init(start: Int, length: Int, surface: String, reading: String,
                rawReading: String? = nil, groupLength: Int? = nil) {
        self.start = start
        self.length = length
        self.surface = surface
        self.reading = reading
        self.rawReading = rawReading
        self.groupLength = groupLength
    }

    public var wasRepaired: Bool { rawReading != nil && rawReading != reading }

    public var end: Int {
        let (sum, overflowed) = start.addingReportingOverflow(length)
        return overflowed ? Int.max : sum
    }
}

public extension Array where Element == SourceReading {
    func validated(against text: String) -> [SourceReading] {
        let chars = [Character](text)
        var kept: [SourceReading] = []
        for r in sorted(by: { $0.start < $1.start }) {
            guard r.length > 0, !r.reading.isEmpty,
                  r.start >= 0, r.end <= chars.count,
                  String(chars[r.start..<r.end]) == r.surface,
                  r.start >= (kept.last?.end ?? 0) else { continue }
            kept.append(r)
        }
        return kept
    }
}

public enum SourceReadingOverlay {
    public static func apply(_ readings: [SourceReading],
                             to tokens: [Token],
                             text: String) -> [Token] {
        var out = tokens
        for (i, book) in bookReadings(readings, tokens: tokens, text: text).enumerated() {
            guard let book else { continue }
            out[i] = Token(surface: tokens[i].surface,
                           reading: preferred(book: book, tokenizer: tokens[i].reading),
                           dictionaryForm: tokens[i].dictionaryForm)
        }
        return out
    }

    /// The book's own reading for each token, or nil where the book has not described one.
    ///
    /// Two shapes count as described. Annotations that tile the token exactly (`秀` + `一` over the
    /// token 秀一) concatenate. And an annotation covering only part of the token composes with the
    /// literal kana of the remainder: `響`, ruby'd ひび, inside the token 響け yields ひびけ. That
    /// second shape is the ordinary one in Japanese books — ruby marks the kanji stem and leaves
    /// the okurigana bare — and dropping it cost narration every reading a book had spelled out.
    ///
    /// A remainder that is not kana refuses the whole token: the book has said nothing about how to
    /// read those characters, and guessing is how a wrong reading reaches a paid narration.
    public static func bookReadings(_ readings: [SourceReading],
                                    tokens: [Token],
                                    text: String) -> [String?] {
        let empty = [String?](repeating: nil, count: tokens.count)
        let valid = readings.validated(against: text)
        guard !valid.isEmpty else { return empty }

        let raw = Array(text)
        var normalizedCache: [Int: Int] = [:]
        func normalized(_ rawOffset: Int) -> Int {
            if let hit = normalizedCache[rawOffset] { return hit }
            let n = Normalize.nfkc(String(raw[0..<rawOffset])).count
            normalizedCache[rawOffset] = n
            return n
        }

        var startingAt: [Int: (end: Int, reading: SourceReading)] = [:]
        for r in valid { startingAt[normalized(r.start)] = (normalized(r.end), r) }

        var out = empty
        var offset = 0
        for (i, token) in tokens.enumerated() {
            let chars = Array(token.surface)
            let start = offset
            let end = offset + chars.count
            offset = end

            var position = start
            var surface = "", reading = "", annotated = false
            while position < end {
                if let hit = startingAt[position], hit.end <= end {
                    surface += hit.reading.surface
                    reading += hit.reading.reading
                    position = hit.end
                    annotated = true
                } else {
                    let c = chars[position - start]
                    guard Furigana.isKana(c) else { break }
                    surface.append(c)
                    reading.append(c)
                    position += 1
                }
            }
            guard position == end, annotated,
                  Normalize.nfkc(surface) == token.surface else { continue }
            out[i] = reading
        }
        return out
    }

    static func preferred(book: String, tokenizer: String?) -> String {
        guard let tokenizer, !tokenizer.isEmpty,
              KanaRepair.flattened(tokenizer) == KanaRepair.flattened(book) else { return book }
        return tokenizer
    }
}
