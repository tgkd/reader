import Foundation

/// Decodes raw `.txt` bytes that may be UTF-8, Shift-JIS / Windows-31J (CP932),
/// or EUC-JP — the encodings Japanese plain-text files turn up in. Honors a
/// UTF-8/UTF-16 BOM, then tries UTF-8 → Shift-JIS → EUC-JP, **rejecting any
/// decode that produced a U+FFFD replacement character** (mojibake) so a wrong
/// guess falls through to the next encoding instead of returning garbage.
public enum JapaneseTextDecoder {
    /// Returns the decoded string, or `nil` only if every candidate encoding
    /// failed outright (empty input decodes to "").
    public static func decode(_ data: Data) -> String? {
        if let bomDecoded = decodeBOM(data) { return bomDecoded }
        if data.isEmpty { return "" }

        // First-success-by-order misfires because EUC-JP kana bytes decode "validly"
        // (no U+FFFD) as Shift-JIS half-width-katakana garbage. So decode under every
        // candidate that produces no replacement char and pick the most plausibly-
        // Japanese result by a simple character-class score.
        var best: (score: Int, text: String)?
        for encoding in [String.Encoding.utf8, .shiftJIS, .japaneseEUC] {
            guard let s = String(data: data, encoding: encoding),
                  !s.unicodeScalars.contains("\u{FFFD}") else { continue }
            let score = plausibility(s)
            if best == nil || score > best!.score { best = (score, s) }
        }
        if let best { return best.text }

        // Last resort: a REPAIRING UTF-8 decode (substitutes U+FFFD for bad bytes)
        // so a mostly-readable file with a few corrupt bytes never hard-fails to nil.
        return String(decoding: data, as: UTF8.self)
    }

    /// Rough "is this Japanese text" score: reward hiragana/katakana/kanji, penalize
    /// half-width-katakana runs (the classic EUC-as-Shift-JIS mojibake signature) and
    /// C0 control chars. Higher is better.
    private static func plausibility(_ s: String) -> Int {
        var score = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF, 0x4E00...0x9FFF, 0x3400...0x4DBF: score += 2   // kana + kanji
            case 0xFF61...0xFF9F: score -= 2                                     // half-width katakana
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F: score -= 4               // C0 controls (not \t\n\r)
            default: break
            }
        }
        return score
    }

    /// Strip and honor a leading byte-order mark if present.
    private static func decodeBOM(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        return nil
    }
}
