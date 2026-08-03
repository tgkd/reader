import Foundation

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
