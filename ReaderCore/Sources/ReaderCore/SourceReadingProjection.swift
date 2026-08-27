import Foundation

struct SourceReadingProjection {
    struct NormalizedAnnotation {
        let start: Int
        let surface: String
        let reading: String
    }

    let readings: [SourceReading]

    private let raw: [Character]
    private let offsets: [Int: Int]
    private let startingAt: [Int: (end: Int, reading: SourceReading)]

    init(text: String, readings: [SourceReading]) {
        let valid = readings.validated(against: text)
        let raw = Array(text)
        var memo: [Int: Int] = [:]
        func normalized(_ rawOffset: Int) -> Int {
            if let hit = memo[rawOffset] { return hit }
            let n = Normalize.nfkc(String(raw[0..<rawOffset])).count
            memo[rawOffset] = n
            return n
        }

        var startingAt: [Int: (end: Int, reading: SourceReading)] = [:]
        for r in valid {
            let start = normalized(r.start), end = normalized(r.end)
            startingAt[start] = (end, r)
        }

        self.readings = valid
        self.raw = raw
        self.offsets = memo
        self.startingAt = startingAt
    }

    func normalizedOffset(_ rawOffset: Int) -> Int {
        if let hit = offsets[rawOffset] { return hit }
        return Normalize.nfkc(String(raw[0..<rawOffset])).count
    }

    func spans(of readings: [SourceReading]) -> [NormalizedAnnotation] {
        readings.map {
            NormalizedAnnotation(start: normalizedOffset($0.start),
                                 surface: Normalize.nfkc($0.surface),
                                 reading: Normalize.nfkc($0.reading))
        }
    }

    func joining(_ tokens: [Token]) -> [Token] {
        guard !readings.isEmpty, !tokens.isEmpty else { return tokens }

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
        for reading in readings {
            let start = normalizedOffset(reading.start), end = normalizedOffset(reading.end)
            guard end > start,
                  let first = tokenIndex(containing: start),
                  let last = tokenIndex(containing: end - 1),
                  last > first else { continue }
            for i in first..<last { joinsNext[i] = true }
        }
        guard joinsNext.contains(true) else { return tokens }

        let chars = Array(tokens.map(\.surface).joined())

        var out: [Token] = []
        var i = 0
        while i < tokens.count {
            var j = i
            while j < tokens.count - 1, joinsNext[j] { j += 1 }
            let parts = tokens[i...j]
            let span = starts[i]..<(starts[j] + tokens[j].surface.count)
            if j > i, composed(span, chars: chars, base: 0) != nil {
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

    func bookReadings(of tokens: [Token]) -> [String?] {
        let empty = [String?](repeating: nil, count: tokens.count)
        guard !readings.isEmpty else { return empty }

        var out = empty
        var offset = 0
        for (i, token) in tokens.enumerated() {
            let chars = Array(token.surface)
            let start = offset
            let end = offset + chars.count
            offset = end
            out[i] = composed(start..<end, chars: chars, base: start)
        }
        return out
    }

    func bookReading(of tokens: [Token], covering range: ClosedRange<Int>,
                     startingAt offset: Int) -> String? {
        guard range.lowerBound >= 0, range.upperBound < tokens.count else { return nil }
        let chars = Array(tokens[range].map(\.surface).joined())
        return composed(offset..<(offset + chars.count), chars: chars, base: offset)
    }

    private func composed(_ range: Range<Int>, chars: [Character], base: Int) -> String? {
        var position = range.lowerBound
        var surface = "", reading = "", annotated = false
        while position < range.upperBound {
            if let hit = startingAt[position], hit.end <= range.upperBound {
                surface += hit.reading.surface
                reading += hit.reading.reading
                position = hit.end
                annotated = true
            } else {
                let c = chars[position - base]
                guard Furigana.isKana(c) else { return nil }
                surface.append(c)
                reading.append(c)
                position += 1
            }
        }
        let slice = String(chars[(range.lowerBound - base)..<(range.upperBound - base)])
        guard annotated, Normalize.nfkc(surface) == slice else { return nil }
        return reading
    }
}
