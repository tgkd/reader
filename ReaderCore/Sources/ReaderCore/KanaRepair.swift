import Foundation

public enum KanaRepair {
    private static let smallToLarge: [Character: Character] = [
        "ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お",
        "っ": "つ", "ゃ": "や", "ゅ": "ゆ", "ょ": "よ", "ゎ": "わ",
        "ァ": "ア", "ィ": "イ", "ゥ": "ウ", "ェ": "エ", "ォ": "オ",
        "ッ": "ツ", "ャ": "ヤ", "ュ": "ユ", "ョ": "ヨ", "ヮ": "ワ",
    ]

    public static func flattened(_ s: String) -> String {
        String(s.map { smallToLarge[$0] ?? $0 })
    }

    public static func containsSmallKana(_ s: String) -> Bool {
        s.contains { smallToLarge[$0] != nil }
    }

    private static let flattenedYoon = try! NSRegularExpression(
        pattern: "([きしちにひみりぎじぢびぴキシチニヒミリギジヂビピ])([やゆよヤユヨ])")

    private static let flattenedDigraph = try! NSRegularExpression(
        pattern: "([フヴ])([アイエオ])")

    public static func looksFlattened(_ readings: [String]) -> Bool {
        guard readings.count >= 12 else { return false }
        guard !readings.contains(where: containsSmallKana) else { return false }
        return readings.contains { r in
            let range = NSRange(r.startIndex..., in: r)
            return flattenedYoon.firstMatch(in: r, range: range) != nil
                || flattenedDigraph.firstMatch(in: r, range: range) != nil
        }
    }

    public static func restoreSmallKana(_ s: String) -> String {
        var out: [Character] = []
        out.reserveCapacity(s.count)
        for ch in s {
            if let prev = out.last,
               (yoonTriggers.contains(prev) && yoonFollowers.contains(ch))
                || (digraphTriggers.contains(prev) && digraphFollowers.contains(ch)),
               let small = largeToSmall[ch] {
                out.append(small)
            } else {
                out.append(ch)
            }
        }
        return String(out)
    }

    private static let largeToSmall: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (small, large) in smallToLarge where small != "っ" && small != "ッ" {
            m[large] = small
        }
        return m
    }()

    private static let yoonTriggers = Set("きしちにひみりぎじぢびぴキシチニヒミリギジヂビピ")
    private static let yoonFollowers = Set("やゆよヤユヨ")
    private static let digraphTriggers = Set("フヴ")
    private static let digraphFollowers = Set("アイエオ")
}
