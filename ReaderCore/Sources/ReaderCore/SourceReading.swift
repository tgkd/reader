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
        let valid = readings.validated(against: text)
        guard !valid.isEmpty else { return tokens }

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

        var out = tokens
        var offset = 0
        for (i, token) in tokens.enumerated() {
            let start = offset
            let end = offset + token.surface.count
            offset = end

            var position = start
            var parts: [SourceReading] = []
            while position < end, let hit = startingAt[position], hit.end <= end {
                parts.append(hit.reading)
                position = hit.end
            }
            guard position == end, !parts.isEmpty,
                  Normalize.nfkc(parts.map(\.surface).joined()) == token.surface else { continue }

            out[i] = Token(surface: token.surface,
                           reading: preferred(book: parts.map(\.reading).joined(),
                                              tokenizer: token.reading),
                           dictionaryForm: token.dictionaryForm)
        }
        return out
    }

    static func preferred(book: String, tokenizer: String?) -> String {
        guard let tokenizer, !tokenizer.isEmpty,
              KanaRepair.flattened(tokenizer) == KanaRepair.flattened(book) else { return book }
        return tokenizer
    }
}
