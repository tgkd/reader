import Foundation

/// An ElevenLabs voice usable for narration. `id` is the `voice_id` sent to the
/// API. `isPremade` matters on the free tier — only premade voices work via the
/// API (library voices return HTTP 402).
public struct Voice: Identifiable, Codable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let isPremade: Bool

    public init(id: String, name: String, isPremade: Bool) {
        self.id = id
        self.name = name
        self.isPremade = isPremade
    }

    /// George — premade, free-tier API-usable; `multilingual_v2` speaks Japanese
    /// with any voice. The capture-spike default.
    public static let george = Voice(id: "JBFqnCBsd6RMkjVDRZzb", name: "George", isPremade: true)
}

/// ElevenLabs synthesis model — the quality vs. cost/latency lever.
public enum SynthesisModel: String, Codable, CaseIterable {
    /// Highest quality; the default for prose.
    case multilingualV2 = "eleven_multilingual_v2"
    /// Cheaper and lower latency; for bulk/preview synthesis.
    case flashV2_5 = "eleven_flash_v2_5"

    public var displayName: String {
        switch self {
        case .multilingualV2: return "Multilingual v2 — quality"
        case .flashV2_5: return "Flash v2.5 — fast"
        }
    }
}
