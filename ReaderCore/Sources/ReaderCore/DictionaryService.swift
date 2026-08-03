import Foundation

public struct DictionaryEntry: Identifiable, Equatable {
    public let id: Int
    public let word: String
    public let reading: String
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

public protocol DictionaryService {
    func lookup(dictionaryForm: String, reading: String?) -> DictionaryEntry?
}
