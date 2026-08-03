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
    /// Readings the SOURCE supplied for runs of `text` — publisher ruby, kept because
    /// the tokenizer cannot produce them (see `SourceReading`). Empty for every
    /// format that has no such markup (PDF, TXT, pasted, OCR) and for books imported
    /// before this existed.
    public var sourceReadings: [SourceReading]

    public init(id: UUID = UUID(), title: String? = nil, text: String,
                sourceReadings: [SourceReading] = []) {
        self.id = id
        self.title = title
        self.text = text
        self.sourceReadings = sourceReadings
    }

    private enum CodingKeys: String, CodingKey { case id, title, text, sourceReadings }

    /// Hand-written rather than synthesized, and this is not a style choice.
    ///
    /// Swift's synthesized decoder does NOT fall back to a property's default value
    /// when the key is absent — only `Optional` tolerates that — so adding
    /// `sourceReadings` with `= []` would make every previously written
    /// `library.json` fail to decode. `DiskLibraryStore` treats an undecodable
    /// library as corruption: it starts EMPTY and moves the file aside as
    /// `library.json.corrupt`. That file is the only copy of every imported book's
    /// text, so the synthesized conformance would have silently emptied users'
    /// shelves on upgrade.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        // Annotations are metadata: a malformed list must never cost the chapter's
        // text. Anything unreadable degrades to "no readings", which is exactly the
        // pre-existing behaviour.
        sourceReadings = (try? c.decodeIfPresent([SourceReading].self, forKey: .sourceReadings)) ?? []
    }

    /// Omitted when empty, so a library of PDFs and pasted text stays byte-identical
    /// to what older builds wrote and can still be read by them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(text, forKey: .text)
        if !sourceReadings.isEmpty { try c.encode(sourceReadings, forKey: .sourceReadings) }
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
    /// Source readings are rebased onto each part, not dropped: their offsets index
    /// the WHOLE chapter's text, so a part starting at character 4,000 would
    /// otherwise carry annotations pointing thousands of characters past its end.
    /// An annotation straddling a cut is discarded — half a ruby base has no reading.
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
                                     surface: $0.surface, reading: $0.reading) }
            return Chapter(title: title.map { "\($0) (\(i + 1))" }, text: part,
                           sourceReadings: mine)
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
