import Foundation

public struct SynthesizedAudio: Equatable {
    public let audio: Data
    public let alignment: Alignment
    public let text: String

    public init(audio: Data, alignment: Alignment, text: String) {
        self.audio = audio
        self.alignment = alignment
        self.text = text
    }
}

public struct SynthesisRequest: Equatable {
    public let text: String
    public let voice: Voice

    public init(text: String, voice: Voice = .shizuka) {
        self.text = text
        self.voice = voice
    }

    public var cacheKey: ContentKey {
        ContentKey(text: text, voice: voice.id)
    }

    public var legacyCacheKeys: [ContentKey] {
        LegacyAudioCache.modelIDs.map {
            ContentKey(text: text, voice: voice.id, legacyModel: $0)
        }
    }

    public var cacheKeyCandidates: [ContentKey] { [cacheKey] + legacyCacheKeys }
}

public protocol TTSService {
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio
}
