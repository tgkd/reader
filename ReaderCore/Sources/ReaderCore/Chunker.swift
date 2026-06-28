import Foundation

/// Splits a chapter's text into segments each under a character cap, so a long
/// chapter can be synthesized in multiple TTS requests (ElevenLabs caps input at
/// 10k chars for `multilingual_v2`, 40k for flash). Splits ONLY on
/// sentence/paragraph boundaries where possible, and is **lossless**: the returned
/// segments concatenate back to the exact input (no trimming, no inserted
/// separators). That invariant is load-bearing — the stitched alignment's
/// characters must reconstruct the original text 1:1 for `CharTokenMapper` and
/// the furigana segmentation to line up.
public enum Chunker {
    /// Stay safely under the `multilingual_v2` 10k-char input cap (margin for the
    /// rare case where a terminator-less unit nudges a segment over).
    public static let defaultMaxChars = 9_000

    /// Greedy pack: accumulate whole sentence units (delimited by 。！？!?。and
    /// newlines, the delimiter kept with its sentence) up to `maxChars`. A single
    /// unit longer than `maxChars` (e.g. a terminator-less wall of text) is
    /// hard-split at the cap. Counting is by `Character` (grapheme) so surrogate
    /// kanji and combining marks count as one, matching how the API counts input.
    public static func split(_ text: String, maxChars: Int = defaultMaxChars) -> [String] {
        precondition(maxChars > 0, "maxChars must be positive")
        if text.isEmpty { return [] }
        if text.count <= maxChars { return [text] }

        var segments: [String] = []
        var current = ""
        var currentCount = 0

        for unit in sentenceUnits(text) {
            let unitCount = unit.count

            // An over-cap unit can't fit any segment: flush, then hard-split it.
            if unitCount > maxChars {
                if !current.isEmpty {
                    segments.append(current); current = ""; currentCount = 0
                }
                segments.append(contentsOf: hardSplit(unit, maxChars: maxChars))
                continue
            }

            // Adding this unit would overflow the current segment: start a new one.
            if currentCount + unitCount > maxChars && !current.isEmpty {
                segments.append(current); current = ""; currentCount = 0
            }
            current += unit
            currentCount += unitCount
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    /// Break text into sentence units, keeping each terminator attached to the
    /// sentence it ends. Newlines are terminators too, so paragraph breaks fall on
    /// segment boundaries. Lossless: the units concatenate back to `text`.
    private static func sentenceUnits(_ text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
        var units: [String] = []
        var unit = ""
        for ch in text {
            unit.append(ch)
            if terminators.contains(ch) {
                units.append(unit)
                unit = ""
            }
        }
        if !unit.isEmpty { units.append(unit) }
        return units
    }

    /// Last-resort split of a single over-cap unit, by grapheme count.
    private static func hardSplit(_ unit: String, maxChars: Int) -> [String] {
        var out: [String] = []
        var seg = ""
        var n = 0
        for ch in unit {
            seg.append(ch)
            n += 1
            if n == maxChars { out.append(seg); seg = ""; n = 0 }
        }
        if !seg.isEmpty { out.append(seg) }
        return out
    }
}
