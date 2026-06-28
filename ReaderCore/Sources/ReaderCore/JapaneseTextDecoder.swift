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

        for encoding in [String.Encoding.utf8, .shiftJIS, .japaneseEUC] {
            if let s = String(data: data, encoding: encoding), !s.unicodeScalars.contains("\u{FFFD}") {
                return s
            }
        }
        // Last resort: lenient UTF-8 so a mostly-readable file never hard-fails.
        return String(data: data, encoding: .utf8)
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
