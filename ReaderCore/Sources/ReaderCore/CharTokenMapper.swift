import Foundation

/// Folds ElevenLabs per-character timings into per-token spans.
///
/// ElevenLabs returns timings per character; Japanese has no spaces, so word
/// boundaries must come from a tokenizer. The naive approach — assume the
/// returned `characters[]` equals the tokenized input 1:1 and slice by length —
/// breaks whenever the API collapses whitespace, emits punctuation as its own
/// character, or drops/inserts a character (surrogate pairs, normalization).
///
/// This instead runs a tolerant **two-pointer alignment** between the
/// concatenated token-surface character stream and `alignment.characters[]`,
/// skipping inserted/dropped characters on either side within a lookahead
/// window. Each token's interval is the min start / max end over the alignment
/// characters that matched it; tokens that matched nothing are interpolated
/// from their neighbours. A final monotonic clamp guarantees token start times
/// never run backwards.
public enum CharTokenMapper {
    public struct Options {
        /// How far ahead to search, on either side, to resync after a mismatch.
        public var lookahead: Int
        public init(lookahead: Int = 8) { self.lookahead = lookahead }
    }

    public static func map(tokens: [Token],
                           alignment: Alignment,
                           options: Options = Options()) -> [TokenSpan] {
        guard !tokens.isEmpty else { return [] }

        // Flatten token surfaces into (owningTokenIndex, character).
        var tokChars: [(t: Int, ch: Character)] = []
        for (ti, tok) in tokens.enumerated() {
            for ch in tok.surface { tokChars.append((ti, ch)) }
        }

        // Each alignment element is normally one character; take its first
        // grapheme (nil for empty strings the API occasionally emits).
        let aChars: [Character?] = alignment.characters.map { $0.first }

        // alignment indices matched to each token.
        var matched: [[Int]] = Array(repeating: [], count: tokens.count)

        let w = max(1, options.lookahead)
        var i = 0   // index into tokChars
        var j = 0   // index into aChars

        while i < tokChars.count && j < aChars.count {
            let tc = tokChars[i].ch
            let ac = aChars[j]

            if let ac, ac == tc {
                matched[tokChars[i].t].append(j)
                i += 1; j += 1
                continue
            }

            // Mismatch: try to resync. `aAhead` = the token char appears later
            // in the alignment (API inserted chars, e.g. whitespace/punctuation
            // the tokenizer dropped) → skip alignment forward. `tAhead` = the
            // alignment char appears later in the tokens (API dropped chars) →
            // skip tokens forward.
            let aAhead = firstIndex(of: tc, in: aChars, from: j + 1, within: w)
            let tAhead = ac.flatMap { firstIndex(ofToken: $0, in: tokChars, from: i + 1, within: w) }

            switch (aAhead, tAhead) {
            case let (a?, t?):
                if (a - j) <= (t - i) { j = a } else { i = t }
            case let (a?, nil):
                j = a
            case let (nil, t?):
                i = t
            case (nil, nil):
                // Substitution: pair them up and advance both.
                matched[tokChars[i].t].append(j)
                i += 1; j += 1
            }
        }

        var spans = buildSpans(tokens: tokens, matched: matched, alignment: alignment)
        interpolateUnmatched(&spans, alignment: alignment)
        clampMonotonic(&spans)
        return spans
    }

    // MARK: - Span assembly

    private static func buildSpans(tokens: [Token],
                                   matched: [[Int]],
                                   alignment: Alignment) -> [TokenSpan] {
        tokens.enumerated().map { ti, tok in
            let idxs = matched[ti]
            let start = idxs.map { alignment.startTime(at: $0) }.min() ?? .nan
            let end = idxs.map { alignment.endTime(at: $0) }.max() ?? .nan
            return TokenSpan(index: ti, surface: tok.surface, reading: tok.reading,
                             dictionaryForm: tok.dictionaryForm,
                             start: start, end: end, matchedChars: idxs.count)
        }
    }

    /// Fill intervals for tokens that matched no alignment character: anchor to
    /// the previous token's end and the next matched token's start.
    private static func interpolateUnmatched(_ spans: inout [TokenSpan], alignment: Alignment) {
        let fallbackEnd = alignment.endTimes.last ?? 0
        for k in spans.indices where spans[k].start.isNaN {
            let prevEnd = (0..<k).reversed().first { !spans[$0].end.isNaN }.map { spans[$0].end } ?? 0
            let nextStart = ((k + 1)..<spans.count).first { !spans[$0].start.isNaN }.map { spans[$0].start } ?? fallbackEnd
            spans[k].start = prevEnd
            spans[k].end = max(prevEnd, nextStart)
        }
    }

    /// Token starts must never decrease, and end must be ≥ start.
    private static func clampMonotonic(_ spans: inout [TokenSpan]) {
        for k in spans.indices {
            if k > 0 { spans[k].start = max(spans[k].start, spans[k - 1].start) }
            spans[k].end = max(spans[k].end, spans[k].start)
        }
    }

    // MARK: - Lookahead helpers

    private static func firstIndex(of ch: Character, in arr: [Character?],
                                   from: Int, within w: Int) -> Int? {
        let end = min(arr.count, from + w)
        var k = from
        while k < end { if arr[k] == ch { return k }; k += 1 }
        return nil
    }

    private static func firstIndex(ofToken ch: Character, in arr: [(t: Int, ch: Character)],
                                   from: Int, within w: Int) -> Int? {
        let end = min(arr.count, from + w)
        var k = from
        while k < end { if arr[k].ch == ch { return k }; k += 1 }
        return nil
    }
}
