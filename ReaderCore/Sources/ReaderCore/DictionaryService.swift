import Foundation

/// One dictionary entry for tap-to-define, shaped from jisho-seed.db
/// (`words` + `meanings` + optional `examples`). The reader resolves a token's
/// `dictionary_form` to one of these.
public struct DictionaryEntry: Identifiable, Equatable {
    public let id: Int          // words.id (or a stable id for seeded mock entries)
    public let word: String     // headword — kanji form if any, else kana
    public let reading: String  // display reading (katakana for loanwords — never reading_hiragana)
    public let priorityRank: Int
    public let senses: [Sense]
    public let example: Example?

    public init(id: Int, word: String, reading: String,
                priorityRank: Int = 999, senses: [Sense], example: Example? = nil) {
        self.id = id
        self.word = word
        self.reading = reading
        self.priorityRank = priorityRank
        self.senses = senses
        self.example = example
    }
}

/// One JMdict sense: a set of glosses sharing a part-of-speech. (In the DB each
/// `meanings` row is one sense; glosses are joined by "; ", POS by ", ", and POS
/// is empty on continuation senses — carry the previous one forward.)
public struct Sense: Equatable {
    public let glosses: [String]
    public let partsOfSpeech: [String]
    public let misc: String?
    public let field: String?

    public init(glosses: [String], partsOfSpeech: [String] = [], misc: String? = nil, field: String? = nil) {
        self.glosses = glosses
        self.partsOfSpeech = partsOfSpeech
        self.misc = misc
        self.field = field
    }
}

/// An example sentence; sparse in the data (~5% of entries), so always optional.
public struct Example: Equatable {
    public let japanese: String
    public let english: String
    public let reading: String?

    public init(japanese: String, english: String, reading: String? = nil) {
        self.japanese = japanese
        self.english = english
        self.reading = reading
    }
}

/// Resolves a MeCab `dictionary_form` (+ the reading from the SAME tokenize pass,
/// to disambiguate homographs) to a dictionary entry. Base UI uses an in-memory
/// mock; production swaps in a read-only SQLite impl over the bundled
/// jisho-seed.db (Phase 5) — same protocol, no UI change.
public protocol DictionaryService {
    func lookup(dictionaryForm: String, reading: String?) -> DictionaryEntry?
}
