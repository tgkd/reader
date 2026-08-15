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
        let joined = joiningAcrossAnnotations(readings, tokens: tokens, text: text)
        var out = joined
        for (i, book) in bookReadings(readings, tokens: joined, text: text).enumerated() {
            guard let book else { continue }
            out[i] = Token(surface: joined[i].surface,
                           reading: preferred(book: book, tokenizer: joined[i].reading),
                           dictionaryForm: joined[i].dictionaryForm)
        }
        return out
    }

    public static func joiningAcrossAnnotations(_ readings: [SourceReading],
                                                tokens: [Token],
                                                text: String) -> [Token] {
        let valid = readings.validated(against: text)
        guard !valid.isEmpty, !tokens.isEmpty else { return tokens }

        let raw = Array(text)
        var normalizedCache: [Int: Int] = [:]
        func normalized(_ rawOffset: Int) -> Int {
            if let hit = normalizedCache[rawOffset] { return hit }
            let n = Normalize.nfkc(String(raw[0..<rawOffset])).count
            normalizedCache[rawOffset] = n
            return n
        }

        var starts: [Int] = []
        var cursor = 0
        for token in tokens {
            starts.append(cursor)
            cursor += token.surface.count
        }
        let total = cursor

        func tokenIndex(containing offset: Int) -> Int? {
            guard offset >= 0, offset < total else { return nil }
            var low = 0, high = starts.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if starts[mid] <= offset { low = mid } else { high = mid - 1 }
            }
            return low
        }

        var joinsNext = [Bool](repeating: false, count: tokens.count)
        for reading in valid {
            let start = normalized(reading.start), end = normalized(reading.end)
            guard end > start,
                  let first = tokenIndex(containing: start),
                  let last = tokenIndex(containing: end - 1),
                  last > first else { continue }
            for i in first..<last { joinsNext[i] = true }
        }
        guard joinsNext.contains(true) else { return tokens }

        var startingAt: [Int: (end: Int, reading: SourceReading)] = [:]
        for r in valid { startingAt[normalized(r.start)] = (normalized(r.end), r) }

        let chars = Array(tokens.map(\.surface).joined())
        func composes(_ range: Range<Int>) -> Bool {
            var position = range.lowerBound
            var surface = "", annotated = false
            while position < range.upperBound {
                if let hit = startingAt[position], hit.end <= range.upperBound {
                    surface += hit.reading.surface
                    position = hit.end
                    annotated = true
                } else {
                    guard Furigana.isKana(chars[position]) else { return false }
                    surface.append(chars[position])
                    position += 1
                }
            }
            return annotated && Normalize.nfkc(surface) == String(chars[range])
        }

        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            var j = i
            while j < tokens.count - 1, joinsNext[j] { j += 1 }
            let parts = tokens[i...j]
            if j > i, composes(starts[i]..<(starts[j] + tokens[j].surface.count)) {
                let readings = parts.map(\.reading)
                out.append(Token(surface: parts.map(\.surface).joined(),
                                 reading: readings.contains(where: { $0 == nil })
                                     ? nil : readings.compactMap { $0 }.joined(),
                                 dictionaryForm: nil))
            } else {
                out.append(contentsOf: parts)
            }
            i = j + 1
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
