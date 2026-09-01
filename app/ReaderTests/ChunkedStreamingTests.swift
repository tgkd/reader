import XCTest
import ReaderCore
@testable import Reader

final class ChunkedStreamingTests: XCTestCase {
    private enum FakeError: Error { case failed }

    private final class Recorder: @unchecked Sendable {
        struct Event { let key: String; let audio: Data; let alignment: Alignment }
        private let lock = NSLock()
        private(set) var events: [Event] = []
        private(set) var requested: [String] = []
        func publish(_ key: ContentKey, _ audio: Data, _ alignment: Alignment) {
            lock.withLock { events.append(Event(key: key.value, audio: audio, alignment: alignment)) }
        }
        func request(_ text: String) { lock.withLock { requested.append(text) } }
        var streamedAudio: Data { lock.withLock { events.reduce(Data()) { $0 + $1.audio } } }
        var streamedCharacters: [String] { lock.withLock { events.flatMap { $0.alignment.characters } } }
        var streamedEnds: [Double] { lock.withLock { events.flatMap { $0.alignment.endTimes } } }
    }

    private struct StreamingTTS: TTSService {
        let recorder: Recorder
        var failOn: String? = nil
        var audioBytesPerCharacter: Int = 1

        func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
            recorder.request(request.text.value)
            if let failOn, request.text.value == failOn { throw FakeError.failed }
            let chars = request.text.value.map(String.init)
            let starts = chars.indices.map(Double.init)
            let ends = chars.indices.map { Double($0 + 1) }
            let slice = { (i: Int) in Data(repeating: UInt8(65 + i % 26),
                                           count: self.audioBytesPerCharacter) }
            if let sink = SynthesisChunkForwarding.sink {
                for i in chars.indices {
                    sink(slice(i), Alignment(characters: [chars[i]],
                                             startTimes: [starts[i]], endTimes: [ends[i]]))
                }
            }
            var audio = Data()
            for i in chars.indices { audio.append(slice(i)) }
            return SynthesizedAudio(
                audio: audio,
                alignment: Alignment(characters: chars, startTimes: starts, endTimes: ends),
                text: request.text.value)
        }
    }

    private final class MemoryStore: GeneratedAudioStore, @unchecked Sendable {
        private let lock = NSLock()
        private var map: [String: SynthesizedAudio] = [:]
        func load(_ key: ContentKey) -> SynthesizedAudio? { lock.withLock { map[key.value] } }
        func save(_ audio: SynthesizedAudio, for key: ContentKey) { lock.withLock { map[key.value] = audio } }
        func has(_ key: ContentKey) -> Bool { lock.withLock { map[key.value] != nil } }
        func remove(_ key: ContentKey) { lock.withLock { _ = map.removeValue(forKey: key.value) } }
    }

    private func service(_ recorder: Recorder, store: GeneratedAudioStore?,
                         maxChars: Int, failOn: String? = nil,
                         audioBytesPerCharacter: Int = 1) -> ChunkingTTSService {
        ChunkingTTSService(
            inner: StreamingTTS(recorder: recorder, failOn: failOn,
                                audioBytesPerCharacter: audioBytesPerCharacter),
            store: store, maxChars: { maxChars },
            onChunk: { key, audio, alignment in recorder.publish(key, audio, alignment) })
    }

    func testWhatIsStreamedEqualsWhatIsSealed() async throws {
        let recorder = Recorder()
        let text = "あいう。かきく。さしす。"
        let request = SynthesisRequest(text: text, voice: .shizuka)
        XCTAssertEqual(Chunker.split(Normalize.nfkc(text), maxChars: 4).count, 3)

        let sealed = try await service(recorder, store: MemoryStore(), maxChars: 4)
            .synthesize(request)

        XCTAssertEqual(Set(recorder.events.map(\.key)), [request.cacheKey.value],
                       "every chunk must be published under the chapter key")
        XCTAssertEqual(recorder.streamedAudio, sealed.audio)
        XCTAssertEqual(recorder.streamedCharacters, sealed.alignment.characters)
        XCTAssertEqual(recorder.streamedEnds, sealed.alignment.endTimes)
    }

    func testSegmentsAreRequestedInReadingOrder() async throws {
        let recorder = Recorder()
        let text = "あいう。かきく。さしす。"
        _ = try await service(recorder, store: MemoryStore(), maxChars: 4)
            .synthesize(SynthesisRequest(text: text, voice: .shizuka))

        XCTAssertEqual(recorder.requested, Chunker.split(Normalize.nfkc(text), maxChars: 4))
    }

    func testACachedPrefixIsReplayedSoTheReaderStillGetsTheStart() async throws {
        let recorder = Recorder()
        let store = MemoryStore()
        let text = "あいう。かきく。さしす。"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 4)
        let warm = Recorder()
        let first = try await StreamingTTS(recorder: warm).synthesize(
            SynthesisRequest(text: segments[0], voice: .shizuka))
        store.save(first, for: SynthesisRequest(text: segments[0], voice: .shizuka).cacheKey)

        let sealed = try await service(recorder, store: store, maxChars: 4)
            .synthesize(SynthesisRequest(text: text, voice: .shizuka))

        XCTAssertEqual(recorder.requested, Array(segments.dropFirst()),
                       "the cached segment must not be billed again")
        XCTAssertEqual(recorder.streamedAudio, sealed.audio,
                       "a cached segment must still reach the reader")
        XCTAssertEqual(recorder.streamedEnds, sealed.alignment.endTimes)
    }

    func testDuplicateSegmentsAreBilledOnceAndStreamedAtEveryOccurrence() async throws {
        let recorder = Recorder()
        let text = "あいう。あいう。"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 4)
        XCTAssertEqual(segments, ["あいう。", "あいう。"])

        let sealed = try await service(recorder, store: MemoryStore(), maxChars: 4)
            .synthesize(SynthesisRequest(text: text, voice: .shizuka))

        XCTAssertEqual(recorder.requested, ["あいう。"], "identical segments are billed once")
        XCTAssertEqual(recorder.streamedCharacters, sealed.alignment.characters)
        XCTAssertEqual(recorder.streamedEnds, sealed.alignment.endTimes,
                       "the second occurrence must be replayed at its own offset")
    }

    func testTrailingAudioBeyondTheAlignmentShiftsTheFollowingSegment() async throws {
        let recorder = Recorder()
        let text = "あいう。かきく。"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 4)
        let bytes = Int(NarrationAudio.mp3BytesPerSecond)

        let sealed = try await service(recorder, store: MemoryStore(), maxChars: 4,
                                       audioBytesPerCharacter: bytes)
            .synthesize(SynthesisRequest(text: text, voice: .shizuka))

        let advance = Double(segments[0].count)
        XCTAssertEqual(sealed.alignment.endTimes[4], advance + 1, accuracy: 1e-9,
                       "the second segment starts after the first segment's AUDIO, not its alignment")
        XCTAssertEqual(recorder.streamedEnds, sealed.alignment.endTimes)
    }

    func testAFailureKeepsTheStreamedPrefixAndStopsBilling() async {
        let recorder = Recorder()
        let text = "あいう。かきく。さしす。"
        let segments = Chunker.split(Normalize.nfkc(text), maxChars: 4)

        do {
            _ = try await service(recorder, store: MemoryStore(), maxChars: 4, failOn: segments[1])
                .synthesize(SynthesisRequest(text: text, voice: .shizuka))
            XCTFail("the failing segment should have thrown")
        } catch {}

        XCTAssertEqual(recorder.requested, [segments[0], segments[1]])
        XCTAssertEqual(recorder.streamedCharacters, segments[0].map(String.init),
                       "the reader keeps the prefix it was already given")
    }
}
