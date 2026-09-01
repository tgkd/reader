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

    public static func splitForReading(_ text: String, target: Int, hardMax: Int) -> [String] {
        precondition(target > 0 && hardMax >= target, "hardMax must be at least target")
        if text.isEmpty { return [] }
        if text.count <= hardMax { return [text] }

        var units: [String] = []
        for paragraph in paragraphUnits(text) {
            if paragraph.count <= hardMax { units.append(paragraph); continue }
            for sentence in sentenceUnits(paragraph) {
                if sentence.count <= hardMax { units.append(sentence) }
                else { units.append(contentsOf: hardSplit(sentence, maxChars: hardMax)) }
            }
        }

        var blocks: [String] = []
        var current = ""
        for unit in units {
            if !current.isEmpty && current.count + unit.count > hardMax {
                blocks.append(current); current = ""
            }
            current += unit
            if current.count >= target { blocks.append(current); current = "" }
        }
        if !current.isEmpty {
            if let last = blocks.last, last.count + current.count <= hardMax {
                blocks[blocks.count - 1] = last + current
            } else {
                blocks.append(current)
            }
        }
        return blocks
    }

    private static func paragraphUnits(_ text: String) -> [String] {
        var units: [String] = []
        var unit = ""
        var sawBreak = false
        for ch in text {
            if ch == "\n" {
                unit.append(ch)
                sawBreak = true
                continue
            }
            if sawBreak, !unit.isEmpty {
                units.append(unit)
                unit = ""
            }
            sawBreak = false
            unit.append(ch)
        }
        if !unit.isEmpty { units.append(unit) }
        return units
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
