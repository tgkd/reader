import XCTest
@testable import ReaderCore

final class LegacyModelCacheTests: XCTestCase {
    private final class MemoryStore: GeneratedAudioStore {
        private(set) var entries: [ContentKey: SynthesizedAudio] = [:]
        private(set) var loads: [ContentKey] = []
        func load(_ key: ContentKey) -> SynthesizedAudio? { loads.append(key); return entries[key] }
        func save(_ audio: SynthesizedAudio, for key: ContentKey) { entries[key] = audio }
        func remove(_ key: ContentKey) { entries[key] = nil }
    }

    private func audio(_ text: String) -> SynthesizedAudio {
        SynthesizedAudio(audio: Data([0xFF, 0xFB]),
                         alignment: Alignment(characters: [], startTimes: [], endTimes: []),
                         text: text)
    }

    func testCandidatesLeadWithTheCurrentKeyThenTheModelQualifiedOnes() {
        let request = SynthesisRequest(text: "吾輩は猫である", voice: .shizuka)
        XCTAssertEqual(request.cacheKeyCandidates.first, request.cacheKey)
        XCTAssertEqual(request.legacyCacheKeys,
                       LegacyAudioCache.modelIDs.map {
                           ContentKey(canonical: request.text, voice: Voice.shizuka.id,
                                      legacyModel: $0)
                       })
    }

    func testTheCurrentKeyIsNeverOneOfTheLegacyKeys() {
        let request = SynthesisRequest(text: "本", voice: .shizuka)
        XCTAssertEqual(request.cacheKeyCandidates.count, LegacyAudioCache.modelIDs.count + 1)
        XCTAssertFalse(request.legacyCacheKeys.contains(request.cacheKey))
        XCTAssertEqual(Set(request.cacheKeyCandidates).count, request.cacheKeyCandidates.count,
                       "candidates must be distinct, or a probe wastes lookups")
    }

    func testLoadFindsAudioLeftByEveryShippedModel() throws {
        let text = "吾輩は猫である"
        let request = SynthesisRequest(text: text, voice: .shizuka)

        for model in LegacyAudioCache.modelIDs {
            let store = MemoryStore()
            let legacyKey = ContentKey(text: text, voice: Voice.shizuka.id, legacyModel: model)
            store.save(audio(text), for: legacyKey)

            XCTAssertNil(store.load(request.cacheKey), "precondition: nothing under the new key")
            let hit = try XCTUnwrap(store.loadAllowingLegacyModel(request), "\(model) unreachable")
            XCTAssertEqual(hit.audio.text, text)
            XCTAssertEqual(hit.key, legacyKey)
            XCTAssertTrue(store.hasAllowingLegacyModel(request))
        }
    }

    func testCurrentKeyWins() throws {
        let store = MemoryStore()
        let request = SynthesisRequest(text: "本", voice: .shizuka)
        store.save(audio("current"), for: request.cacheKey)
        store.save(audio("legacy"),
                   for: ContentKey(text: "本", voice: Voice.shizuka.id,
                                   legacyModel: "eleven_v3"))

        XCTAssertEqual(try XCTUnwrap(store.loadAllowingLegacyModel(request)).audio.text, "current")
        XCTAssertEqual(store.loads, [request.cacheKey])
    }

    func testAnotherVoiceIsNotAFallback() {
        let store = MemoryStore()
        store.save(audio("george"), for: SynthesisRequest(text: "本", voice: .george).cacheKey)
        XCTAssertNil(store.loadAllowingLegacyModel(SynthesisRequest(text: "本", voice: .shizuka)))
    }

    func testTheShippedModelHistoryIsComplete() {
        XCTAssertEqual(LegacyAudioCache.modelIDs,
                       ["eleven_flash_v2_5", "eleven_v3", "eleven_multilingual_v2"])
    }
}
