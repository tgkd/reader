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

public extension Chapter {
    /// Upper bound on a single chapter's length. The reader draws one CoreText
    /// surface per chapter; beyond a few thousand characters that surface exceeds the
    /// platform's max layer/texture size and renders BLANK (and tokenizing + laying
    /// out the whole thing janks the main thread). Import splits longer chapters into
    /// sub-chapters so every chapter stays renderable — measured: ~4k renders at every
    /// font size, larger blanks. Also keeps each chapter a bounded TTS unit.
    static let maxRenderableChars = 4_000

    /// Split into sub-chapters no longer than `maxChars`, on paragraph/sentence
    /// boundaries (reusing `Chunker`'s lossless splitter). Returns `[self]` when it
    /// already fits; otherwise the parts concatenate back to the original text exactly
    /// and their titles are numbered (`章 (1)`, `章 (2)`, …).
    func splitToRenderable(maxChars: Int = maxRenderableChars) -> [Chapter] {
        guard text.count > maxChars else { return [self] }
        let parts = Chunker.split(text, maxChars: maxChars)
        guard parts.count > 1 else { return [self] }
        return parts.enumerated().map { i, part in
            Chapter(title: title.map { "\($0) (\(i + 1))" }, text: part)
        }
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
