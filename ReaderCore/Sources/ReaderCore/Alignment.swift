import Foundation

/// One ElevenLabs `with-timestamps` alignment block. The three arrays are
/// parallel and index-aligned: `characters[i]` is spoken from `startTimes[i]`
/// to `endTimes[i]` (seconds). Mirrors the HTTP response field
/// `character_start_times_seconds` / `character_end_times_seconds`.
public struct Alignment: Codable, Equatable {
    public let characters: [String]
    public let startTimes: [Double]
    public let endTimes: [Double]

    enum CodingKeys: String, CodingKey {
        case characters
        case startTimes = "character_start_times_seconds"
        case endTimes = "character_end_times_seconds"
    }

    public init(characters: [String], startTimes: [Double], endTimes: [Double]) {
        self.characters = characters
        self.startTimes = startTimes
        self.endTimes = endTimes
    }

    /// Safe start time for an alignment index (clamped to the array bounds).
    /// Empty arrays yield 0 rather than indexing `[-1]` — a malformed response
    /// shouldn't trap here (the request layer rejects it, but this stays total).
    func startTime(at i: Int) -> Double {
        guard !startTimes.isEmpty else { return 0 }
        return startTimes[min(max(i, 0), startTimes.count - 1)]
    }

    /// Safe end time for an alignment index (clamped to the array bounds).
    func endTime(at i: Int) -> Double {
        guard !endTimes.isEmpty else { return 0 }
        return endTimes[min(max(i, 0), endTimes.count - 1)]
    }
}

/// Top-level shape of `POST /v1/text-to-speech/{voice}/with-timestamps`.
/// Prefer `alignment` (original input text) over `normalizedAlignment` so the
/// tokenizer's character indices line up with the text actually displayed.
public struct TimestampedAudio: Decodable {
    public let audioBase64: String
    public let alignment: Alignment?
    public let normalizedAlignment: Alignment?

    enum CodingKeys: String, CodingKey {
        case audioBase64 = "audio_base64"
        case alignment
        case normalizedAlignment = "normalized_alignment"
    }
}
