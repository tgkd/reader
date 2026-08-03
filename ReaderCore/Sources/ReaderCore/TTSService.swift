import Foundation

/// A unit of synthesized narration: the audio bytes plus the char-level
/// alignment that `CharTokenMapper` folds onto token spans. Returned by any
/// `TTSService` — fixture, ElevenLabs-direct, or Worker-proxied — so the reader
/// is agnostic to where audio comes from.
///
/// `alignment` is always the `alignment` block (original text), never
/// `normalized_alignment`, so its indices track the text we tokenize and show.
public struct SynthesizedAudio: Equatable {
    public let audio: Data            // mp3 bytes (AVAudioPlayer(data:)-playable)
    public let alignment: Alignment
    public let text: String           // the exact NFKC text the alignment indexes

    public init(audio: Data, alignment: Alignment, text: String) {
        self.audio = audio
        self.alignment = alignment
        self.text = text
    }
}

/// What to synthesize: text + the voice/model knobs. `cacheKey` is the stable
/// identity used to fetch/store the result.
public struct SynthesisRequest: Equatable {
    public let text: String
    public let voice: Voice
    public let model: SynthesisModel

    public init(text: String, voice: Voice = .shizuka, model: SynthesisModel = .flashV2_5) {
        self.text = text
        self.voice = voice
        self.model = model
    }

    public var cacheKey: ContentKey {
        ContentKey(text: text, voice: voice.id, model: model.rawValue)
    }

    /// The keys this same text+voice may already be cached under from a build whose
    /// DEFAULT MODEL was different, most recent first. Read-only: audio is always
    /// saved under `cacheKey`, so these only ever resolve entries an earlier version
    /// of the app paid for. See `SynthesisModel.previousDefaults`.
    public var legacyCacheKeys: [ContentKey] {
        SynthesisModel.previousDefaults
            .filter { $0 != model }
            .map { ContentKey(text: text, voice: voice.id, model: $0.rawValue) }
    }

    /// Every key worth probing before spending money on this request: the current one
    /// first, then the earlier defaults.
    public var cacheKeyCandidates: [ContentKey] { [cacheKey] + legacyCacheKeys }
}

/// Produces narration + char alignment for a chunk of Japanese text. The reader
/// never assumes a source: a fixture impl serves base UI offline; the Worker
/// impl is the production path (Phase 6). Implementations must NFKC-normalize
/// the request text before sending, identically to the tokenizer.
public protocol TTSService {
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio
}
