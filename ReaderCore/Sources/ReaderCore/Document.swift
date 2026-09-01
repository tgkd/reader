import Foundation

public enum WritingMode: String, Codable, Equatable, Sendable {
    case vertical, horizontal
}

public struct Document: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var author: String?
    public var chapters: [Chapter]
    public var progress: ReadingProgress
    public var writingMode: WritingMode?

    public init(id: UUID = UUID(), title: String, author: String? = nil,
                chapters: [Chapter], progress: ReadingProgress = ReadingProgress(),
                writingMode: WritingMode? = nil) {
        self.id = id
        self.title = title
        self.author = author
        self.chapters = chapters
        self.progress = progress
        self.writingMode = writingMode
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
    static let maxRenderableChars = 1_000
    static let renderableHardMax = 1_400

    func splitToRenderable(maxChars: Int = maxRenderableChars,
                           hardMax: Int = renderableHardMax) -> [Chapter] {
        let cap = max(maxChars, hardMax)
        guard text.count > cap else { return [self] }
        let parts = Chunker.splitForReading(text, target: maxChars, hardMax: cap)
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
    public var duration: Double
    public var charOffset: Int

    public init(chapterIndex: Int = 0, time: Double = 0, duration: Double = 0,
                charOffset: Int = 0) {
        self.chapterIndex = chapterIndex
        self.time = time
        self.duration = duration
        self.charOffset = charOffset
    }

    private enum CodingKeys: String, CodingKey { case chapterIndex, time, duration, charOffset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterIndex = (try? c.decodeIfPresent(Int.self, forKey: .chapterIndex)) ?? 0
        time = (try? c.decodeIfPresent(Double.self, forKey: .time)) ?? 0
        duration = (try? c.decodeIfPresent(Double.self, forKey: .duration)) ?? 0
        charOffset = (try? c.decodeIfPresent(Int.self, forKey: .charOffset)) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(chapterIndex, forKey: .chapterIndex)
        try c.encode(time, forKey: .time)
        if duration > 0 { try c.encode(duration, forKey: .duration) }
        if charOffset > 0 { try c.encode(charOffset, forKey: .charOffset) }
    }
}

public extension Document {
    var readFraction: Double {
        let lengths = chapters.map { Double($0.text.count) }
        let total = lengths.reduce(0, +)
        guard total > 0, !lengths.isEmpty else { return 0 }
        let index = min(max(0, progress.chapterIndex), lengths.count - 1)
        let consumed = lengths[..<index].reduce(0, +)
        let within: Double
        if progress.duration > 0 {
            within = min(1, max(0, progress.time / progress.duration))
        } else if lengths[index] > 0 {
            within = min(1, max(0, Double(progress.charOffset) / lengths[index]))
        } else {
            within = 0
        }
        return min(1, (consumed + within * lengths[index]) / total)
    }
}
