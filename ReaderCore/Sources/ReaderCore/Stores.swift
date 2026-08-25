import Foundation

public protocol LibraryStore {
    func all() -> [Document]
    func save(_ document: Document)
    func remove(_ id: Document.ID)
    @discardableResult
    func flush() -> Bool
}

public extension LibraryStore {
    @discardableResult
    func flush() -> Bool { true }

    func current(_ document: Document) -> Document {
        all().first { $0.id == document.id } ?? document
    }
}

public protocol GeneratedAudioStore {
    func load(_ key: ContentKey) -> SynthesizedAudio?
    func save(_ audio: SynthesizedAudio, for key: ContentKey)
    func has(_ key: ContentKey) -> Bool
    func remove(_ key: ContentKey)
    func clear()
    func totalBytes() -> Int
}

public extension GeneratedAudioStore {
    func has(_ key: ContentKey) -> Bool { load(key) != nil }
    func remove(_ key: ContentKey) {}
    func clear() {}
    func totalBytes() -> Int { 0 }

    func loadAllowingLegacyModel(_ request: SynthesisRequest) -> (key: ContentKey, audio: SynthesizedAudio)? {
        for key in request.cacheKeyCandidates {
            if let audio = load(key) { return (key, audio) }
        }
        return nil
    }

    func hasAllowingLegacyModel(_ request: SynthesisRequest) -> Bool {
        request.cacheKeyCandidates.contains { has($0) }
    }
}
