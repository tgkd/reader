import Foundation

public struct SurfaceInfo: Equatable, Sendable {
    public let priorityRank: Int
    public let matchedWord: Bool
    public let matchedReadingOnly: Bool
    public let hasExpressionSense: Bool
    public let hasNonExpressionSense: Bool

    public init(priorityRank: Int, matchedWord: Bool, matchedReadingOnly: Bool,
                hasExpressionSense: Bool, hasNonExpressionSense: Bool) {
        self.priorityRank = priorityRank
        self.matchedWord = matchedWord
        self.matchedReadingOnly = matchedReadingOnly
        self.hasExpressionSense = hasExpressionSense
        self.hasNonExpressionSense = hasNonExpressionSense
    }

    public var isExpressionOnly: Bool { hasExpressionSense && !hasNonExpressionSense }
}

public struct SpanCandidate: Equatable, Sendable {
    public let indices: ClosedRange<Int>
    public let surface: String
    public let isSeed: Bool
    public let info: SurfaceInfo?

    public init(indices: ClosedRange<Int>, surface: String, isSeed: Bool, info: SurfaceInfo?) {
        self.indices = indices
        self.surface = surface
        self.isSeed = isSeed
        self.info = info
    }
}

public let maxSpanLookupTokens = 3

public func isAllKana(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    return text.unicodeScalars.allSatisfy { scalar in
        let v = scalar.value
        return (0x3041...0x309F).contains(v) || (0x30A0...0x30FF).contains(v)
            || (0xFF66...0xFF9D).contains(v) || v == 0x30FC
    }
}

public func spanLookupCandidates(
    spans: [TokenSpan],
    at index: Int,
    maxTokens: Int = maxSpanLookupTokens,
    isWord: (String) -> Bool,
    info lookup: (String) -> SurfaceInfo?
) -> [SpanCandidate] {
    guard spans.indices.contains(index), maxTokens > 0, isWord(spans[index].surface) else { return [] }

    var starts = [index]
    var start = index
    while start > 0, starts.count <= maxTokens, isWord(spans[start - 1].surface) {
        start -= 1
        starts.append(start)
    }
    var ends = [index]
    var end = index
    while end < spans.count - 1, ends.count <= maxTokens, isWord(spans[end + 1].surface) {
        end += 1
        ends.append(end)
    }

    func surface(_ range: ClosedRange<Int>) -> String {
        spans[range].map(\.surface).joined()
    }

    let seedSurface = spans[index].surface
    let seedInfo = lookup(seedSurface)
    let seed = SpanCandidate(indices: index...index, surface: seedSurface, isSeed: true, info: seedInfo)
    let seedIsCommonOrdinary = seedInfo.map { $0.priorityRank < 999 && $0.hasNonExpressionSense } ?? false

    var seen = Set([seedSurface])
    var promoted: [SpanCandidate] = []
    var demoted: [SpanCandidate] = []

    for s in starts {
        for e in ends where !(s == index && e == index) {
            let range = s...e
            let text = surface(range)
            guard !seen.contains(text), let info = lookup(text) else { continue }
            seen.insert(text)
            let candidate = SpanCandidate(indices: range, surface: text, isSeed: false, info: info)
            let spuriousKana = range.count > 1 && info.matchedReadingOnly && isAllKana(text)
            if spuriousKana || (seedIsCommonOrdinary && info.isExpressionOnly) {
                demoted.append(candidate)
            } else {
                promoted.append(candidate)
            }
        }
    }

    func longerFirst(_ a: SpanCandidate, _ b: SpanCandidate) -> Bool {
        if a.surface.count != b.surface.count { return a.surface.count > b.surface.count }
        return (a.info?.priorityRank ?? 999) < (b.info?.priorityRank ?? 999)
    }
    promoted.sort(by: longerFirst)
    demoted.sort(by: longerFirst)

    return promoted + [seed] + demoted
}
