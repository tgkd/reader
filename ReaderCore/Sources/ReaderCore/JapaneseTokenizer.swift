import Foundation
import Mecab_Swift
import IPADic

/// Produces ordered tokens (surface + reading) for a Japanese string. The
/// reader's single source of truth: one tokenize pass feeds word spans (sync),
/// readings (furigana) and dictionary base forms (tap-to-define).
public protocol JapaneseTokenizer {
    func tokenize(_ text: String) -> [Token]
}

/// MeCab + IPADic tokenizer. `tokenize` normalizes with NFKC first so the
/// surfaces line up with text sent to TTS under the same normalization.
///
/// Tokenizes with `.katakana` transliteration rather than `.hiragana`: under
/// `.hiragana`, Mecab-Swift hiragana-izes BOTH `reading` and `dictionaryForm`,
/// which would turn the kanji lemma (生まれる) into kana (うまれる) and break
/// dictionary lookup. So we keep the kanji `dictionaryForm` and convert the
/// katakana reading to hiragana ourselves — yielding surface + hiragana reading
/// + kanji lemma from one pass.
public final class MeCabTokenizer: JapaneseTokenizer {
    private let mecab: Mecab_Swift.Tokenizer

    public init() throws {
        self.mecab = try Mecab_Swift.Tokenizer(dictionary: IPADic())
    }

    public func tokenize(_ text: String) -> [Token] {
        let normalized = Normalize.nfkc(text)
        return mecab.tokenize(text: normalized, transliteration: .katakana).map { a in
            let reading = a.reading.isEmpty ? nil : Self.hiragana(a.reading)
            let lemma = (a.dictionaryForm.isEmpty || a.dictionaryForm == "*") ? nil : a.dictionaryForm
            return Token(surface: a.base, reading: reading, dictionaryForm: lemma)
        }
    }

    /// Katakana → hiragana by the fixed 0x60 block offset (U+30A1…U+30F6).
    /// Marks shared by both kana (ー U+30FC, ・) and any non-katakana are left
    /// untouched. Dependency-free and deterministic.
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
