import Foundation

public enum Chunker {
    public static let defaultMaxChars = 9_000

    public static func split(_ text: String, maxChars: Int = defaultMaxChars) -> [String] {
        precondition(maxChars > 0, "maxChars must be positive")
        if text.isEmpty { return [] }
        if text.count <= maxChars { return [text] }

        var segments: [String] = []
        var current = ""
        var currentCount = 0

        for unit in sentenceUnits(text) {
            let unitCount = unit.count

            if unitCount > maxChars {
                if !current.isEmpty {
                    segments.append(current); current = ""; currentCount = 0
                }
                segments.append(contentsOf: hardSplit(unit, maxChars: maxChars))
                continue
            }

            if currentCount + unitCount > maxChars && !current.isEmpty {
                segments.append(current); current = ""; currentCount = 0
            }
            current += unit
            currentCount += unitCount
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

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
