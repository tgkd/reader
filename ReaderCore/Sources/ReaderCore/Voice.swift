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
    /// NOT USABLE FOR A SYNCED HIGHLIGHT — kept only so audio generated under it
    /// stays nameable. `eleven_v3` speaks material that is not in the text and
    /// returns no timestamps for it, so its alignment does not describe its own
    /// audio. Measured 2026-08-03 on a real 851-char chapter: 9.64 s of undescribed
    /// audio on the streaming route, 6.94 s buffered, while `multilingual_v2` and
    /// `flash_v2_5` came in at 0.04 s on the same text. Every other check passes —
    /// the arrays are parallel and monotonic and the characters reproduce the text —
    /// which is why it went unnoticed: the damage is a highlight that leads the
    /// narration by however long the insertion was. It is also, per ElevenLabs' own
    /// documentation, an alpha research preview whose output is "not fully
    /// deterministic", and the defect is content- and length-dependent: a 119-char
    /// probe comes back clean.
    case v3 = "eleven_v3"
    /// The pre-2026-07-29 default. Alignment is exact; reads pre-war orthography
    /// wrong (生れ as なまれ rather than うまれ), which is what drove the move to v3.
    case multilingualV2 = "eleven_multilingual_v2"
    /// The default since 2026-08-03, chosen on how it READS: side by side on a probe
    /// built from the hard cases (pre-war orthography, 日本橋, the book's surnames,
    /// counters) it handled proper nouns more convincingly than `multilingual_v2`.
    /// Alignment fidelity did not decide it — this, `multilingual_v2` and
    /// `turbo_v2_5` all describe their own audio within 0.05 s on a full 851-char
    /// chapter, so the choice was purely the voice. Being cheaper per character is
    /// incidental, and its own selling point (latency) is irrelevant here: generation
    /// already outruns playback behind the reader's head start.
    case flashV2_5 = "eleven_flash_v2_5"
    /// Untested for reading quality, but alignment-exact (0.05 s on the same 851-char
    /// chapter) and a tier above flash in the family. The candidate to compare
    /// against the default when narration quality is revisited.
    case turboV2_5 = "eleven_turbo_v2_5"

    public var displayName: String {
        switch self {
        case .v3: return "v3 — do not use"
        case .multilingualV2: return "Multilingual v2"
        case .flashV2_5: return "Flash v2.5"
        case .turboV2_5: return "Turbo v2.5"
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
        case .turboV2_5: return 36_000      // API limit 40,000
        }
    }

    /// The models that have been this app's default, most recent first — the shipped
    /// history, not the case list.
    ///
    /// A default change moves every future `ContentKey`, so audio a user ALREADY PAID
    /// FOR sits behind a key nothing constructs any more: silently re-synthesized (and
    /// re-billed) for a subscriber, and simply gone for a lapsed one, who cannot
    /// regenerate it at all. That is the same "unreachable cache = a second bill" trap
    /// `Voice.george` is kept in the catalog to avoid, except a model default is worse:
    /// the voice is a persisted per-user choice, while the model is hard-coded, so
    /// changing it strands EVERY existing user at once and breaks the standing promise
    /// that cached narration plays regardless of entitlement.
    ///
    /// Cache probes therefore fall back through this list (read-only — new synthesis
    /// always uses the current default, so a legacy entry is only ever played, never
    /// written). Append the outgoing default here whenever the default changes; a
    /// model that was never a default has no keys on anyone's disk to find.
    ///
    /// A `.v3` entry replayed this way keeps that model's alignment defect: its
    /// timings may not describe all of its audio, so the highlight can lead the
    /// narration and then HOLD at the alignment's frontier (`SpanTimeline.index(at:)`
    /// never answers past the last timed span). Degraded sync on audio the user owns
    /// beats silently deleting it; Settings' "clear cached audio" is how someone who
    /// would rather pay again gets it regenerated under the current model.
    public static let previousDefaults: [SynthesisModel] = [.v3, .multilingualV2]
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
