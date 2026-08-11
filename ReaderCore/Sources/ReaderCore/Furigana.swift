import Foundation

public enum Furigana {
    public struct Placement: Equatable {
        public let range: Range<Int>
        public let reading: String

        public init(range: Range<Int>, reading: String) {
            self.range = range
            self.reading = reading
        }
    }

    public static func place(surface: String, reading: String?) -> Placement? {
        guard let reading, !reading.isEmpty else { return nil }
        let s = Array(surface)
        let r = Array(reading)
        guard s.contains(where: isKanji) else { return nil }

        var lo = 0, hi = s.count
        var rLo = 0, rHi = r.count
        while hi > lo, rHi > rLo, s[hi - 1] == r[rHi - 1], !isKanji(s[hi - 1]) {
            hi -= 1
            rHi -= 1
        }
        while lo < hi, rLo < rHi, s[lo] == r[rLo], !isKanji(s[lo]) {
            lo += 1
            rLo += 1
        }
        guard lo < hi, rLo < rHi, s[lo..<hi].contains(where: isKanji) else {
            return Placement(range: 0..<s.count, reading: reading)
        }
        return Placement(range: lo..<hi, reading: String(r[rLo..<rHi]))
    }

    static func isKanji(_ c: Character) -> Bool {
        c.unicodeScalars.contains(where: isIdeograph)
    }

    /// Hiragana, katakana, the long-vowel mark and the bare voicing marks.
    ///
    /// Narrower than `!isKanji`, which also admits Latin, digits and punctuation — the distinction
    /// matters wherever an unannotated character has to be read literally.
    static func isKana(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy {
            (0x3041...0x3096).contains($0.value)
                || (0x30A1...0x30FA).contains($0.value)
                || $0.value == 0x30FC
                || $0.value == 0x309B || $0.value == 0x309C
        }
    }

    public static func isIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
             0x20000...0x2EE5D, 0x2F800...0x2FA1F, 0x30000...0x323AF:
            return true
        default:
            return false
        }
    }
}
