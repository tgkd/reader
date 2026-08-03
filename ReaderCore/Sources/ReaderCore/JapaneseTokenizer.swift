import Foundation
import Mecab_Swift
import IPADic

public protocol JapaneseTokenizer {
    func tokenize(_ text: String) -> [Token]
}

public final class MeCabTokenizer: JapaneseTokenizer {
    private let mecab: Mecab_Swift.Tokenizer

    public init() throws {
        self.mecab = try Mecab_Swift.Tokenizer(dictionary: IPADic())
    }

    public func tokenize(_ text: String) -> [Token] {
        let normalized = Normalize.nfkc(text)
        var tokens: [Token] = []
        var cursor = normalized.startIndex
        for a in mecab.tokenize(text: normalized, transliteration: .katakana) {
            if cursor < a.range.lowerBound {
                tokens.append(Token(surface: String(normalized[cursor..<a.range.lowerBound]),
                                    reading: nil, dictionaryForm: nil))
            }
            let reading = Self.usableReading(a.reading)
            let lemma = (a.dictionaryForm.isEmpty || a.dictionaryForm == "*") ? nil : a.dictionaryForm
            tokens.append(Token(surface: a.base, reading: reading, dictionaryForm: lemma))
            cursor = a.range.upperBound
        }
        if cursor < normalized.endIndex {
            tokens.append(Token(surface: String(normalized[cursor...]), reading: nil, dictionaryForm: nil))
        }
        return tokens
    }

    static func usableReading(_ raw: String) -> String? {
        guard !raw.isEmpty, raw != "*",
              !raw.unicodeScalars.contains(where: Furigana.isIdeograph) else { return nil }
        return hiragana(raw)
    }

    static func hiragana(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            if (0x30A1...0x30F6).contains(scalar.value), let h = Unicode.Scalar(scalar.value - 0x60) {
                out.append(h)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }
}
