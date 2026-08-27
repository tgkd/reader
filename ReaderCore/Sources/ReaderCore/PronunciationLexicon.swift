import Foundation

public struct PronunciationRule: Equatable, Sendable, Hashable {
    public let surface: String
    public let reading: String

    public init(surface: String, reading: String) {
        self.surface = surface
        self.reading = reading
    }
}

public enum LexiconRejection: Equatable, Sendable {
    case singleCharacterBase
    case readingNotKana
    case ambiguousInBook([String])
    case readingMatchesSurface
    case unannotatedOccurrence(count: Int)
    case insideLongerReading(String)
    case unconfirmedRepair
}

public struct LexiconCandidate: Equatable, Sendable {
    public let surface: String
    public let reading: String
    public let occurrences: Int
    public let rejection: LexiconRejection?
}

public struct Lexicon: Equatable, Sendable {
    public let rules: [PronunciationRule]
    public let rejected: [LexiconCandidate]
}

public enum PronunciationLexicon {
    public static func build(chapters: [Chapter],
                             tokens: [Int: [Token]] = [:],
                             corroborate: (String) -> String? = { _ in nil }) -> Lexicon {
        build(texts: chapters.enumerated().map { ($1.text, $1.sourceReadings, tokens[$0]) },
              isFlattened: chapters.contains { $0.isFlattenedSource },
              corroborate: corroborate)
    }

    public static func build(text: String,
                             readings: [SourceReading],
                             isFlattened: Bool = false,
                             tokens: [Token]? = nil,
                             corroborate: (String) -> String? = { _ in nil }) -> Lexicon {
        build(texts: [(text, readings, tokens)], isFlattened: isFlattened, corroborate: corroborate)
    }

    private static func build(texts: [(text: String, readings: [SourceReading], tokens: [Token]?)],
                              isFlattened: Bool,
                              corroborate: (String) -> String? ) -> Lexicon {
        let parts = texts.map { part -> (normalized: String, spans: [Span], valid: [SourceReading]) in
            let projection = SourceReadingProjection(text: part.text, readings: part.readings)
            let valid = regrouped(projection.readings)
            var spans = projection.spans(of: valid).map {
                Span(start: $0.start, surface: $0.surface, reading: $0.reading)
            }
            if let tokens = part.tokens {
                spans = merging(spans, tokenSpans(projection, tokens: tokens))
            }
            return (Normalize.nfkc(part.text), spans, valid)
        }
        let spans = parts.flatMap(\.spans)
        guard !spans.isEmpty else { return Lexicon(rules: [], rejected: []) }

        let repairedSurfaces = Set(parts.flatMap(\.valid).filter(\.wasRepaired)
            .map { Normalize.nfkc($0.surface) })

        var bySurface: [String: [String: Int]] = [:]
        for span in spans {
            bySurface[span.surface, default: [:]][span.reading, default: 0] += 1
        }

        let ordered = bySurface.keys.sorted { ($0.count, $0) > ($1.count, $1) }

        var rules: [PronunciationRule] = []
        var rejected: [LexiconCandidate] = []

        for surface in ordered {
            let variants = bySurface[surface]!
            let occurrences = variants.values.reduce(0, +)
            let reading = variants.count == 1 ? variants.keys.first! : ""

            func reject(_ why: LexiconRejection) {
                rejected.append(LexiconCandidate(surface: surface,
                                                 reading: reading,
                                                 occurrences: occurrences,
                                                 rejection: why))
            }

            guard surface.count > 1 else { reject(.singleCharacterBase); continue }
            guard variants.count == 1 else {
                reject(.ambiguousInBook(variants.keys.sorted())); continue
            }
            guard isKana(reading) else { reject(.readingNotKana); continue }
            guard reading != surface else { reject(.readingMatchesSurface); continue }

            let unvouched = parts.reduce(0) { total, part in
                let annotated = Set(part.spans.filter { $0.surface == surface }.map(\.start))
                return total + occurrencesOf(surface, in: part.normalized)
                    .filter { !annotated.contains($0) }.count
            }
            guard unvouched == 0 else {
                reject(.unannotatedOccurrence(count: unvouched)); continue
            }

            if let host = spans.first(where: {
                $0.surface != surface
                    && $0.surface.contains(surface)
                    && !$0.reading.contains(reading)
            }) {
                reject(.insideLongerReading(host.surface)); continue
            }

            if isFlattened, repairedSurfaces.contains(surface) {
                guard let tokenizer = corroborate(surface),
                      KanaRepair.flattened(tokenizer) == KanaRepair.flattened(reading) else {
                    reject(.unconfirmedRepair); continue
                }
                rules.append(PronunciationRule(surface: surface, reading: tokenizer))
                continue
            }

            rules.append(PronunciationRule(surface: surface, reading: reading))
        }

        return Lexicon(
            rules: rules.sorted { ($0.surface.count, $0.surface) > ($1.surface.count, $1.surface) },
            rejected: rejected.sorted { $0.surface < $1.surface })
    }

    private struct Span {
        let start: Int
        let surface: String
        let reading: String
    }

    private static func regrouped(_ readings: [SourceReading]) -> [SourceReading] {
        var out: [SourceReading] = []
        var i = 0
        while i < readings.count {
            let head = readings[i]
            guard let span = head.groupLength, span > head.length else {
                out.append(head)
                i += 1
                continue
            }
            var parts = [head]
            var covered = head.length
            var j = i + 1
            while covered < span, j < readings.count, readings[j].start == parts[parts.count - 1].end {
                covered += readings[j].length
                parts.append(readings[j])
                j += 1
            }
            guard covered == span else {
                out.append(head)
                i += 1
                continue
            }
            let repaired = parts.contains(where: \.wasRepaired)
            out.append(SourceReading(
                start: head.start,
                length: covered,
                surface: parts.map(\.surface).joined(),
                reading: parts.map(\.reading).joined(),
                rawReading: repaired ? parts.map { $0.rawReading ?? $0.reading }.joined() : nil))
            i = j
        }
        return out
    }

    /// Whole-token candidates: the book's reading read against the token that contains it.
    ///
    /// `響 → ひび` is a single-character base and refused on sight, which left narration with no
    /// guidance at all for a reading the book had printed. The same annotation seen against its
    /// token is `響け → ひびけ` — two characters, kana, and something the gates below can judge on
    /// its merits. Additive: the per-annotation spans stay, so nothing that used to be admitted
    /// stops being admitted.
    private static func tokenSpans(_ projection: SourceReadingProjection,
                                   tokens: [Token]) -> [Span] {
        let book = projection.bookReadings(of: tokens)
        var starts: [Int] = []
        var cursor = 0
        for token in tokens {
            starts.append(cursor)
            cursor += token.surface.count
        }

        var spans: [Span] = []
        for (i, token) in tokens.enumerated() {
            guard let reading = book[i] else { continue }
            spans.append(Span(start: starts[i], surface: token.surface,
                              reading: Normalize.nfkc(reading)))
            guard token.surface.count == 1,
                  let wider = contextualSpan(projection, tokens: tokens, starts: starts, around: i)
            else { continue }
            spans.append(wider)
        }
        return spans
    }

    static let maxContextTokens = 2
    static let maxContextChars = 8

    private static func contextualSpan(_ projection: SourceReadingProjection,
                                       tokens: [Token],
                                       starts: [Int],
                                       around index: Int) -> Span? {
        var best: Span?
        let first = max(0, index - maxContextTokens)
        let last = min(tokens.count - 1, index + maxContextTokens)
        for lo in stride(from: index, through: first, by: -1) {
            for hi in index...last {
                let surface = tokens[lo...hi].map(\.surface).joined()
                guard surface.count > 1, surface.count <= maxContextChars,
                      !surface.contains(where: { $0.isWhitespace || $0.isNewline }),
                      let reading = projection.bookReading(of: tokens, covering: lo...hi,
                                                           startingAt: starts[lo]),
                      isKana(reading) else { continue }
                let normalized = Normalize.nfkc(reading)
                guard normalized != Normalize.nfkc(surface) else { continue }
                if best == nil || surface.count < best!.surface.count {
                    best = Span(start: starts[lo], surface: surface, reading: normalized)
                }
            }
        }
        return best
    }

    private static func merging(_ spans: [Span], _ others: [Span]) -> [Span] {
        func key(_ s: Span) -> String { "\(s.start)\u{1}\(s.surface)\u{1}\(s.reading)" }
        var seen = Set(spans.map(key))
        return spans + others.filter { seen.insert(key($0)).inserted }
    }

    private static func occurrencesOf(_ needle: String, in haystack: String) -> [Int] {
        let n = Array(needle), h = Array(haystack)
        guard !n.isEmpty, h.count >= n.count else { return [] }
        var hits: [Int] = []
        for i in 0...(h.count - n.count) where Array(h[i..<(i + n.count)]) == n {
            hits.append(i)
        }
        return hits
    }

    private static func isKana(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy(Furigana.isKana)
    }
}
