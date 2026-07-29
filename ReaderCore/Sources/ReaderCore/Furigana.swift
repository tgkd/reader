import Foundation

/// Decides WHERE a token's reading belongs above its surface.
///
/// The tokenizer reports one reading for a whole token, okurigana included
/// (生れ → うまれ, 泣い → ない, いた事 → いたこと). Rendering that reading over the
/// whole token puts kana above kana that already says the same thing. Print
/// convention annotates only the kanji: うま over 生, な over 泣, こと over 事.
///
/// The trim is deliberately conservative — it only removes kana that the surface
/// and the reading *share* at an edge, and never touches a kanji. A token it
/// cannot improve (見当 → けんとう) comes back exactly as before, so this can only
/// narrow an annotation, never move or invent one.
///
/// Interior okurigana (取り消し → とりけし) is out of scope: aligning the 「り」 in
/// the middle needs per-kanji mora alignment, not edge trimming. Those tokens keep
/// today's whole-token annotation.
public enum Furigana {

    /// Which characters of the surface to annotate, and with what.
    public struct Placement: Equatable {
        /// Character (grapheme) offsets into the surface it was computed from.
        public let range: Range<Int>
        public let reading: String

        public init(range: Range<Int>, reading: String) {
            self.range = range
            self.reading = reading
        }
    }

    /// `nil` when the token should carry no furigana at all: no reading, or no
    /// kanji to annotate (kana-only tokens read themselves).
    public static func place(surface: String, reading: String?) -> Placement? {
        guard let reading, !reading.isEmpty else { return nil }
        let s = Array(surface)
        let r = Array(reading)
        guard s.contains(where: isKanji) else { return nil }

        var lo = 0, hi = s.count
        var rLo = 0, rHi = r.count
        // Shared trailing kana: 生れ / うまれ -> 生 / うま.
        while hi > lo, rHi > rLo, s[hi - 1] == r[rHi - 1], !isKanji(s[hi - 1]) {
            hi -= 1
            rHi -= 1
        }
        // Shared leading kana: いた事 / いたこと -> 事 / こと.
        while lo < hi, rLo < rHi, s[lo] == r[rLo], !isKanji(s[lo]) {
            lo += 1
            rLo += 1
        }
        // A trim that consumed the kanji or the whole reading is not an
        // improvement — fall back rather than annotate nothing.
        guard lo < hi, rLo < rHi, s[lo..<hi].contains(where: isKanji) else {
            return Placement(range: 0..<s.count, reading: reading)
        }
        return Placement(range: lo..<hi, reading: String(r[rLo..<rHi]))
    }

    /// CJK Unified Ideographs + Extension A.
    static func isKanji(_ c: Character) -> Bool {
        c.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }
    }
}
