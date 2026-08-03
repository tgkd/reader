import XCTest
@testable import ReaderCore

/// `ContentKey` includes the model, so changing the default default-model moves every
/// key the app constructs. These pin the upgrade path: audio a user already paid for
/// under an earlier default must still resolve, or a lapsed subscriber loses chapters
/// they own and an active one silently pays for them twice.
final class LegacyModelCacheTests: XCTestCase {

    /// An in-memory `GeneratedAudioStore`, counting loads so a probe that walks the
    /// candidates can be told apart from one that doesn't.
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

    func testCandidatesLeadWithTheCurrentKeyThenEarlierDefaults() {
        let request = SynthesisRequest(text: "吾輩は猫である", voice: .shizuka)
        XCTAssertEqual(request.cacheKeyCandidates.first, request.cacheKey)
        XCTAssertEqual(request.legacyCacheKeys,
                       [ContentKey(text: request.text, voice: Voice.shizuka.id,
                                   model: SynthesisModel.v3.rawValue),
                        ContentKey(text: request.text, voice: Voice.shizuka.id,
                                   model: SynthesisModel.multilingualV2.rawValue)])
    }

    /// The current default is never listed twice — a request already made under it has
    /// nothing legacy to fall back to.
    func testARequestUnderAPreviousDefaultDoesNotListItself() {
        let request = SynthesisRequest(text: "本", voice: .shizuka, model: .v3)
        XCTAssertEqual(request.cacheKeyCandidates.count, 2)
        XCTAssertFalse(request.legacyCacheKeys.contains(request.cacheKey))
    }

    /// The whole point: a chapter synthesized when `.v3` was the default still plays
    /// after the default moves, without a new (billed) request.
    func testLoadFindsAudioLeftByAnEarlierDefaultModel() throws {
        let store = MemoryStore()
        let text = "吾輩は猫である"
        let request = SynthesisRequest(text: text, voice: .shizuka)
        store.save(audio(text),
                   for: ContentKey(text: text, voice: Voice.shizuka.id,
                                   model: SynthesisModel.v3.rawValue))

        XCTAssertNil(store.load(request.cacheKey), "precondition: nothing under the new default")
        let hit = try XCTUnwrap(store.loadAllowingLegacyModel(request))
        XCTAssertEqual(hit.audio.text, text)
        // The key comes back so an undecodable entry is evicted where it actually
        // lives, not under the key the caller asked for.
        XCTAssertEqual(hit.key, ContentKey(text: text, voice: Voice.shizuka.id,
                                           model: SynthesisModel.v3.rawValue))
        XCTAssertTrue(store.hasAllowingLegacyModel(request))
    }

    /// A hit under the current default must not go looking any further.
    func testCurrentModelWins() throws {
        let store = MemoryStore()
        let request = SynthesisRequest(text: "本", voice: .shizuka)
        store.save(audio("current"), for: request.cacheKey)
        store.save(audio("legacy"),
                   for: ContentKey(text: "本", voice: Voice.shizuka.id,
                                   model: SynthesisModel.v3.rawValue))

        XCTAssertEqual(try XCTUnwrap(store.loadAllowingLegacyModel(request)).audio.text, "current")
        XCTAssertEqual(store.loads, [request.cacheKey])
    }

    /// The voice is a live user choice, not a legacy key: audio made in another voice
    /// stays invisible, exactly as it would to playback.
    func testAnotherVoiceIsNotAFallback() {
        let store = MemoryStore()
        store.save(audio("george"),
                   for: SynthesisRequest(text: "本", voice: .george, model: .v3).cacheKey)
        XCTAssertNil(store.loadAllowingLegacyModel(SynthesisRequest(text: "本", voice: .shizuka)))
    }

    /// `purgeAudio` sweeps `SynthesisModel.allCases`, so every key a probe can resolve
    /// is one a book deletion can still reclaim.
    func testEveryPreviousDefaultIsStillASweepableCase() {
        for model in SynthesisModel.previousDefaults {
            XCTAssertTrue(SynthesisModel.allCases.contains(model), "\(model) left the enum")
        }
    }
}
