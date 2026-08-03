import Foundation

public enum CharTokenMapper {
    public struct Options {
        public var lookahead: Int
        public init(lookahead: Int = 8) { self.lookahead = lookahead }
    }

    public static func map(tokens: [Token],
                           alignment: Alignment,
                           options: Options = Options()) -> [TokenSpan] {
        guard !tokens.isEmpty else { return [] }

        var tokChars: [(t: Int, ch: Character)] = []
        for (ti, tok) in tokens.enumerated() {
            for ch in tok.surface { tokChars.append((ti, ch)) }
        }

        let aChars: [Character?] = alignment.characters.map { $0.first }

        var matched: [[Int]] = Array(repeating: [], count: tokens.count)

        let w = max(1, options.lookahead)
        var i = 0
        var j = 0

        while i < tokChars.count && j < aChars.count {
            let tc = tokChars[i].ch
            let ac = aChars[j]

            if let ac, ac == tc {
                matched[tokChars[i].t].append(j)
                i += 1; j += 1
                continue
            }

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
                matched[tokChars[i].t].append(j)
                i += 1; j += 1
            }
        }

        var spans = buildSpans(tokens: tokens, matched: matched, alignment: alignment)
        interpolateUnmatched(&spans, alignment: alignment)
        clampMonotonic(&spans)
        return spans
    }

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

    private static func interpolateUnmatched(_ spans: inout [TokenSpan], alignment: Alignment) {
        let fallbackEnd = alignment.endTimes.last ?? 0
        for k in spans.indices where spans[k].start.isNaN {
            let prevEnd = (0..<k).reversed().first { !spans[$0].end.isNaN }.map { spans[$0].end } ?? 0
            let nextStart = ((k + 1)..<spans.count).first { !spans[$0].start.isNaN }.map { spans[$0].start } ?? fallbackEnd
            spans[k].start = prevEnd
            spans[k].end = max(prevEnd, nextStart)
        }
    }

    private static func clampMonotonic(_ spans: inout [TokenSpan]) {
        for k in spans.indices {
            if k > 0 { spans[k].start = max(spans[k].start, spans[k - 1].start) }
            spans[k].end = max(spans[k].end, spans[k].start)
        }
    }

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
