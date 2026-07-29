import Foundation

/// An ElevenLabs voice usable for narration. `id` is the `voice_id` sent to the
/// API. `isPremade` distinguishes ElevenLabs' built-in voices from shared-library
/// ones; both work here because synthesis runs through the Worker's own (paid)
/// ElevenLabs account, not the user's — library voices are only tier-gated for
/// the key that bills them.
public struct Voice: Identifiable, Codable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let isPremade: Bool

    public init(id: String, name: String, isPremade: Bool) {
        self.id = id
        self.name = name
        self.isPremade = isPremade
    }

    /// Shizuka — a native Japanese narration voice, and the default. A model
    /// speaking Japanese through an English-native voice inherits that voice's
    /// phonology: an English accent AND flattened pitch accent (Japanese is
    /// pitch-accented, English is stress-timed), which no request parameter
    /// recovers. Picking a Japanese-native voice is the single largest quality
    /// lever in the whole TTS path.
    public static let shizuka = Voice(id: "WQz3clzUdMqvBf0jswZQ", name: "Shizuka", isPremade: false)

    /// George — the pre-2026-07-29 default (English, premade). Kept in the catalog
    /// on purpose: `ContentKey` includes the voice, so removing it would strand
    /// every chapter an existing user already paid to synthesize (unreachable
    /// cache = a second bill), and `purgeAudio` sweeps `catalog` to clean up.
    public static let george = Voice(id: "JBFqnCBsd6RMkjVDRZzb", name: "George", isPremade: true)

    /// The narration voices offered in Settings — native Japanese voices first,
    /// then the legacy English default. The user's selection persists by `id` and
    /// falls back to `shizuka` if its voice leaves the catalog.
    public static let catalog: [Voice] = [
        shizuka,
        Voice(id: "deKmbWEKZdwxcKxxcfvP", name: "Maiko", isPremade: false),
        Voice(id: "17ljzcHzSunXNkdixIEa", name: "Hirokoji", isPremade: false),
        Voice(id: "Mv8AjrYZCBkdsmDHNwcB", name: "Ishibashi", isPremade: false),
        Voice(id: "ss9cJxDAEMXP4wfQ3GPr", name: "Daisuke", isPremade: false),
        george,
    ]
}

/// ElevenLabs synthesis model — the quality vs. cost/latency lever.
///
/// Every case stays in the enum even when unused as a default: `ContentKey`
/// includes the model, so a removed case would make already-paid audio
/// unnameable — neither playable nor sweepable by `purgeAudio`.
public enum SynthesisModel: String, Codable, CaseIterable {
    /// The default for prose. Reads pre-war orthography correctly where
    /// `multilingual_v2` does not (生れ → うまれ, not なまれ), at identical cost
    /// (1 credit/char). Verified to return char-level timestamps whose
    /// `alignment.characters` reproduce the request text exactly.
    case v3 = "eleven_v3"
    /// The pre-2026-07-29 default.
    case multilingualV2 = "eleven_multilingual_v2"
    /// Cheaper and lower latency; for bulk/preview synthesis.
    case flashV2_5 = "eleven_flash_v2_5"

    public var displayName: String {
        switch self {
        case .v3: return "v3 — quality"
        case .multilingualV2: return "Multilingual v2"
        case .flashV2_5: return "Flash v2.5 — fast"
        }
    }

    /// Per-request input cap, held ~10% under the API's hard limit so a segment
    /// that lands slightly over (a terminator-less unit nudging `Chunker` past the
    /// cap) still fits. v3's limit is half of multilingual_v2's, which inverts the
    /// old safety margin — a fixed chunk size sized for v2 would sail past v3's
    /// limit and take a 400 instead of splitting.
    public var maxRequestChars: Int {
        switch self {
        case .v3: return 4_500              // API limit 5,000
        case .multilingualV2: return 9_000  // API limit 10,000
        case .flashV2_5: return 36_000      // API limit 40,000
        }
    }
}

/// The ElevenLabs request parameters that shape *how* a voice reads, as opposed to
/// *what* it reads. Sent explicitly on every synthesis so behaviour is pinned by
/// this app rather than inherited from whatever settings a shared-library voice's
/// owner happened to save with it.
///
/// Deliberately NOT part of `ContentKey`: retuning these does not invalidate
/// already-paid audio. Change them and existing cached chapters keep their old
/// delivery until they are regenerated for some other reason.
public enum NarrationSettings {
    /// Pinning the language stops the multilingual model from resolving kanji
    /// through Chinese: with no language code its own normalization romanizes
    /// 日本橋 as "Ri Ben Qiao" (pinyin) rather than "nihonbashi".
    public static let languageCode = "ja"

    /// Higher than the API's 0.5 default: long-form narration wants consistent
    /// delivery across a chapter more than it wants expressive range.
    public static let stability = 0.65
    public static let similarityBoost = 0.75
    /// Style > 0 destabilizes delivery and degrades non-English output.
    public static let style = 0.0
    public static let useSpeakerBoost = true
    /// Narration is generated at natural speed; playback rate is a local
    /// `AVAudioPlayer` control, so speed must never be baked into paid audio.
    public static let speed = 1.0
}
