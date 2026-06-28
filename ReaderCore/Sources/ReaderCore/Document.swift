import Foundation

/// A readable work in the library, made of one or more chapters. A chapter's
/// raw `text` is the single thing that gets tokenized and sent to TTS;
/// everything else (token spans, audio, definitions) derives from it.
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

/// One chapter's text. Kept as a chunk; the reader tokenizes and synthesizes it
/// on open (and caches the result by `ContentKey`).
public struct Chapter: Identifiable, Codable, Equatable {
    public let id: UUID
    public var title: String?
    public var text: String

    public init(id: UUID = UUID(), title: String? = nil, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// How far through a document the reader has gotten. `fraction` (0…1) drives the
/// library progress indicator; `chapterIndex` + `time` let the reader resume
/// where playback stopped.
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
