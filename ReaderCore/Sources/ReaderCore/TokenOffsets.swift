import Foundation

public enum TokenOffsets {
    public static func charOffset(ofToken index: Int, in spans: [TokenSpan]) -> Int {
        guard index > 0 else { return 0 }
        let upper = min(index, spans.count)
        return spans[..<upper].reduce(0) { $0 + $1.surface.count }
    }

    public static func token(atCharOffset offset: Int, in spans: [TokenSpan]) -> Int? {
        guard !spans.isEmpty else { return nil }
        guard offset > 0 else { return 0 }
        var consumed = 0
        for (i, span) in spans.enumerated() {
            let next = consumed + span.surface.count
            if offset < next { return i }
            consumed = next
        }
        return spans.count - 1
    }
}
