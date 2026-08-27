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
    public let text: CanonicalText
    public let voice: Voice
    public let pronunciation: [PronunciationRule]

    public init(text: String, voice: Voice,
                pronunciation: [PronunciationRule] = []) {
        self.init(canonical: CanonicalText(text), voice: voice, pronunciation: pronunciation)
    }

    public init(canonical text: CanonicalText, voice: Voice,
                pronunciation: [PronunciationRule] = []) {
        self.text = text
        self.voice = voice
        self.pronunciation = pronunciation
    }

    public var cacheKey: ContentKey {
        ContentKey(canonical: text, voice: voice.id)
    }

    public var legacyCacheKeys: [ContentKey] {
        LegacyAudioCache.modelIDs.map {
            ContentKey(canonical: text, voice: voice.id, legacyModel: $0)
        }
    }

    public var cacheKeyCandidates: [ContentKey] { [cacheKey] + legacyCacheKeys }
}

public protocol TTSService {
    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio
}
