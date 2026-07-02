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
        var tokens: [Token] = []
        var cursor = normalized.startIndex
        for a in mecab.tokenize(text: normalized, transliteration: .katakana) {
            // MeCab drops inter-token whitespace (spaces, newlines, the 　 paragraph
            // indent). Re-emit any gap before this token as an untimed token so the
            // rendered text keeps its paragraphs and line breaks — and so
            // `joined(surfaces) == nfkc(text)` stays exact for char→token mapping.
            if cursor < a.range.lowerBound {
                tokens.append(Token(surface: String(normalized[cursor..<a.range.lowerBound]),
                                    reading: nil, dictionaryForm: nil))
            }
            let reading = a.reading.isEmpty ? nil : Self.hiragana(a.reading)
            let lemma = (a.dictionaryForm.isEmpty || a.dictionaryForm == "*") ? nil : a.dictionaryForm
            tokens.append(Token(surface: a.base, reading: reading, dictionaryForm: lemma))
            cursor = a.range.upperBound
        }
        // Trailing whitespace after the final token.
        if cursor < normalized.endIndex {
            tokens.append(Token(surface: String(normalized[cursor...]), reading: nil, dictionaryForm: nil))
        }
        return tokens
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
