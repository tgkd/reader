import Foundation

/// A tokenizer output unit before timing is attached. `reading` is the kana
/// reading (for furigana); nil when the tokenizer has none. `dictionaryForm` is
/// the kanji lemma/base form (for tap-to-define lookup) — e.g. 生まれた→生まれる,
/// つかぬ→つく; nil for tokens with no distinct lemma (punctuation, symbols).
/// All three come from the SAME tokenize pass — the single source of truth.
public struct Token: Equatable {
    public let surface: String
    public let reading: String?
    public let dictionaryForm: String?

    public init(surface: String, reading: String? = nil, dictionaryForm: String? = nil) {
        self.surface = surface
        self.reading = reading
        self.dictionaryForm = dictionaryForm
    }
}

/// A token with its resolved audio interval, produced by `CharTokenMapper`.
/// `start`/`end` are seconds into the audio. `matchedChars` is the number of
/// the token's characters that aligned to an alignment character — a
/// diagnostic: 0 means the interval was interpolated from neighbours.
public struct TokenSpan: Equatable {
    public let index: Int
    public let surface: String
    public let reading: String?
    public let dictionaryForm: String?
    public var start: Double
    public var end: Double
    public var matchedChars: Int

    public init(index: Int, surface: String, reading: String?, dictionaryForm: String? = nil,
                start: Double, end: Double, matchedChars: Int) {
        self.index = index
        self.surface = surface
        self.reading = reading
        self.dictionaryForm = dictionaryForm
        self.start = start
        self.end = end
        self.matchedChars = matchedChars
    }
}
