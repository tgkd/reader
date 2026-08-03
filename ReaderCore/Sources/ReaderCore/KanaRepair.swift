import Foundation

/// Repairs ruby readings from a source that lost its small kana.
///
/// Some EPUBs are produced by a pipeline that upcases every 小書き kana, so 拗音 and
/// katakana digraphs arrive as full-size characters: じょうぜつ is written じようぜつ,
/// みょうじ as みようじ, サファイア as サフアイア. Measured on 響け！ユーфォニアム 2,
/// **0 of its 208 distinct ruby readings contain a single small kana** while 23 carry a
/// sequence only a flattening could produce — so this is a property of the file, not a
/// handful of typos.
///
/// It matters because the reading is asserted with the book's authority: it replaces the
/// tokenizer's reading, drives the furigana, and would be handed to TTS. Left alone, the
/// import replaces MeCab's correct じょうぜつ with じようぜつ, which is worse than never
/// having read the ruby at all.
public enum KanaRepair {

    private static let smallToLarge: [Character: Character] = [
        "ぁ": "あ", "ぃ": "い", "ぅ": "う", "ぇ": "え", "ぉ": "お",
        "っ": "つ", "ゃ": "や", "ゅ": "ゆ", "ょ": "よ", "ゎ": "わ",
        "ァ": "ア", "ィ": "イ", "ゥ": "ウ", "ェ": "エ", "ォ": "オ",
        "ッ": "ツ", "ャ": "ヤ", "ュ": "ユ", "ョ": "ヨ", "ヮ": "ワ",
    ]

    /// The reading as a flattening pipeline would have left it. Comparing two readings
    /// in this space asks "are these the same reading apart from small kana?".
    public static func flattened(_ s: String) -> String {
        String(s.map { smallToLarge[$0] ?? $0 })
    }

    public static func containsSmallKana(_ s: String) -> Bool {
        s.contains { smallToLarge[$0] != nil }
    }

    /// An い-row kana followed by a full-size や/ゆ/よ — the shape a flattened 拗音 takes.
    private static let flattenedYoon = try! NSRegularExpression(
        pattern: "([きしちにひみりぎじぢびぴキシチニヒミリギジヂビピ])([やゆよヤユヨ])")

    /// フ or ヴ followed by a full-size vowel — a flattened katakana digraph (ファ, ヴィ).
    private static let flattenedDigraph = try! NSRegularExpression(
        pattern: "([フヴ])([アイエオ])")

    /// Does this set of readings come from a flattened source?
    ///
    /// Three conditions together, because any one alone is weak: enough readings to be
    /// meaningful, not one small kana among them, and at least one sequence that a
    /// flattening would explain. A book can legitimately have a few readings with no
    /// small kana; it cannot plausibly have dozens including 拗音-shaped ones and never
    /// once write a 小書き character.
    public static func looksFlattened(_ readings: [String]) -> Bool {
        guard readings.count >= 12 else { return false }
        guard !readings.contains(where: containsSmallKana) else { return false }
        return readings.contains { r in
            let range = NSRange(r.startIndex..., in: r)
            return flattenedYoon.firstMatch(in: r, range: range) != nil
                || flattenedDigraph.firstMatch(in: r, range: range) != nil
        }
    }

    /// Restore the small kana this reading almost certainly had.
    ///
    /// Deliberately only two rules. 拗音 (い-row + や/ゆ/よ) and the フ/ヴ katakana
    /// digraphs are the cases where the full-size spelling is not a plausible word.
    /// Gemination is NOT restored: つ before a consonant is genuinely ambiguous
    /// (まつり is a word), and a wrong 促音 would be stated with the book's authority.
    ///
    /// Restoring is still a judgement, so `SourceReadingOverlay` lets the tokenizer
    /// overrule the result wherever the two readings describe the same word — which is
    /// what makes a mistake here recoverable rather than permanent.
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
