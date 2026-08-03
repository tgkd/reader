import Foundation

public enum JapaneseTextDecoder {
    public static func decode(_ data: Data) -> String? {
        if let bomDecoded = decodeBOM(data) { return bomDecoded }
        if data.isEmpty { return "" }

        var best: (score: Int, text: String)?
        for encoding in [String.Encoding.utf8, .shiftJIS, .japaneseEUC] {
            guard let s = String(data: data, encoding: encoding),
                  !s.unicodeScalars.contains("\u{FFFD}") else { continue }
            let score = plausibility(s)
            if best == nil || score > best!.score { best = (score, s) }
        }
        if let best { return best.text }

        return String(decoding: data, as: UTF8.self)
    }

    private static func plausibility(_ s: String) -> Int {
        var score = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF, 0x4E00...0x9FFF, 0x3400...0x4DBF: score += 2
            case 0xFF61...0xFF9F: score -= 2
            case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F: score -= 4
            default: break
            }
        }
        return score
    }

    private static func decodeBOM(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        if data.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        return nil
    }
}
