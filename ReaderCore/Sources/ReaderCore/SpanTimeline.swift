import Foundation

/// An ordered set of token spans with a fast time→token lookup. Built once per
/// chapter from `CharTokenMapper.map(...)`; the reader advances the highlight by
/// calling `index(at:)` every audio frame.
///
/// This lifts the binary search proven in the sync spike (`SyncModel.indexForTime`)
/// into headless, unit-tested logic so the playback UI carries no algorithm.
public struct SpanTimeline: Equatable {
    public let spans: [TokenSpan]

    public init(_ spans: [TokenSpan]) {
        self.spans = spans
    }

    public var isEmpty: Bool { spans.isEmpty }

    /// Total spoken duration (end of the last span); 0 when empty.
    public var duration: Double { spans.last?.end ?? 0 }

    /// Rightmost token whose `start ≤ t` (binary search). Gives a continuous
    /// highlight that advances and never flickers between tokens. Returns nil
    /// before the first token's start (leading silence) or when empty; once
    /// `t` passes the last start it stays on the last token.
    public func index(at t: Double) -> Int? {
        guard !spans.isEmpty else { return nil }
        var lo = 0, hi = spans.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].start <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? ans : nil
    }

    /// Bounds-checked span access.
    public subscript(_ i: Int) -> TokenSpan? {
        spans.indices.contains(i) ? spans[i] : nil
    }
}

public extension SpanTimeline {
    /// Render-only timeline (no audio): spans carry surface + reading +
    /// dictionaryForm for furigana / tap-to-define, with zero timing. Used when the
    /// reader shows text without generated speech (free tier / pre-synthesis). The
    /// renderer reads only surface/reading + token index, so timing-less spans draw
    /// the full surface; `index(at:)` is never queried (no player → no tick).
    init(untimedTokens tokens: [Token]) {
        self.init(tokens.enumerated().map { i, t in
            TokenSpan(index: i, surface: t.surface, reading: t.reading,
                      dictionaryForm: t.dictionaryForm, start: 0, end: 0, matchedChars: 0)
        })
    }
}
