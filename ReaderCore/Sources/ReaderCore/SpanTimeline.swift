import Foundation

public struct SpanTimeline: Equatable {
    public let spans: [TokenSpan]
    private let lastTimedIndex: Int?

    public init(_ spans: [TokenSpan]) {
        self.spans = spans
        self.lastTimedIndex = spans.lastIndex { $0.matchedChars > 0 }
    }

    public var isEmpty: Bool { spans.isEmpty }

    public var duration: Double { spans.last?.end ?? 0 }

    public var timedExtent: Double { lastTimedIndex.map { spans[$0].end } ?? 0 }

    public func index(at t: Double) -> Int? {
        guard !spans.isEmpty, let lastTimedIndex else { return nil }
        var lo = 0, hi = spans.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].start <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? min(ans, lastTimedIndex) : nil
    }

    public subscript(_ i: Int) -> TokenSpan? {
        spans.indices.contains(i) ? spans[i] : nil
    }
}

public struct TimelineRefreshPolicy: Equatable, Sendable {
    public let batchSeconds: Double
    public let safetySeconds: Double

    public init(batchSeconds: Double, safetySeconds: Double) {
        self.batchSeconds = batchSeconds
        self.safetySeconds = safetySeconds
    }

    public func shouldRebuild(alignedTime: Double,
                              builtTo: Double,
                              timedExtent: Double,
                              playhead: Double,
                              rate: Double) -> Bool {
        guard alignedTime > builtTo else { return false }
        if alignedTime - builtTo >= batchSeconds { return true }
        guard rate > 0 else { return false }
        return (timedExtent - playhead) / rate < safetySeconds
    }
}

public extension SpanTimeline {
    init(untimedTokens tokens: [Token]) {
        self.init(tokens.enumerated().map { i, t in
            TokenSpan(index: i, surface: t.surface, reading: t.reading,
                      dictionaryForm: t.dictionaryForm, start: 0, end: 0, matchedChars: 0)
        })
    }
}
