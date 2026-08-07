import Foundation

public struct Document: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var author: String?
    public var chapters: [Chapter]
    public var progress: ReadingProgress

    public init(id: UUID = UUID(), title: String, author: String? = nil,
                chapters: [Chapter], progress: ReadingProgress = ReadingProgress()) {
        self.id = id
        self.title = title
        self.author = author
        self.chapters = chapters
        self.progress = progress
    }
}

public struct Chapter: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String?
    public var text: String
    public var sourceReadings: [SourceReading]

    public var isFlattenedSource: Bool

    public init(id: UUID = UUID(), title: String? = nil, text: String,
                sourceReadings: [SourceReading] = [], isFlattenedSource: Bool = false) {
        self.id = id
        self.title = title
        self.text = text
        self.sourceReadings = sourceReadings
        self.isFlattenedSource = isFlattenedSource
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, text, sourceReadings, isFlattenedSource
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        sourceReadings = (try? c.decodeIfPresent([SourceReading].self, forKey: .sourceReadings)) ?? []
        isFlattenedSource = (try? c.decodeIfPresent(Bool.self, forKey: .isFlattenedSource)) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(text, forKey: .text)
        if !sourceReadings.isEmpty { try c.encode(sourceReadings, forKey: .sourceReadings) }
        if isFlattenedSource { try c.encode(true, forKey: .isFlattenedSource) }
    }
}

public extension Chapter {
    static let maxRenderableChars = 4_000

    func splitToRenderable(maxChars: Int = maxRenderableChars) -> [Chapter] {
        guard text.count > maxChars else { return [self] }
        let parts = Chunker.split(text, maxChars: maxChars)
        guard parts.count > 1 else { return [self] }
        let readings = sourceReadings.validated(against: text)
        var cursor = 0
        return parts.enumerated().map { i, part in
            let lower = cursor, upper = cursor + part.count
            cursor = upper
            let mine = readings
                .filter { $0.start >= lower && $0.end <= upper }
                .map { SourceReading(start: $0.start - lower, length: $0.length,
                                     surface: $0.surface, reading: $0.reading,
                                     rawReading: $0.rawReading, groupLength: $0.groupLength) }
            return Chapter(title: title.map { "\($0) (\(i + 1))" }, text: part,
                           sourceReadings: mine, isFlattenedSource: isFlattenedSource)
        }
    }
}

public struct ReadingProgress: Codable, Equatable {
    public var chapterIndex: Int
    public var time: Double
    public var fraction: Double

    public init(chapterIndex: Int = 0, time: Double = 0, fraction: Double = 0) {
        self.chapterIndex = chapterIndex
        self.time = time
        self.fraction = fraction
    }
}
