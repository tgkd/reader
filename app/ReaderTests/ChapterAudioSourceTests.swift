import XCTest
@testable import Reader

/// `ChapterAudioSource` is fed chunk by chunk from `SynthesisStream` while the synthesis
/// request is still in flight, and the request separately returns the whole chapter.
/// Those two finish independently, so sealing has to be reconciled against the complete
/// audio rather than trusting whichever arrived first.
final class ChapterAudioSourceTests: XCTestCase {

    private func chunk(_ byte: UInt8, _ count: Int) -> Data {
        Data(repeating: byte, count: count)
    }

    /// THE regression. The request's `await` can resume before the final stream chunk is
    /// delivered; sealing on the streamed bytes alone drops the tail permanently, because
    /// the reader clears `progressive` at the same moment and the late chunk is discarded.
    /// Heard as the chapter stopping a few words before the text ends. Does not reproduce
    /// in the simulator, where the two land together — it needs a real network.
    func testSealingRecoversATailTheStreamNeverDelivered() {
        let complete = chunk(0xAA, 1_000) + chunk(0xBB, 200)
        let source = ChapterAudioSource(expectedBytes: 5_000)
        source.append(complete.prefix(1_000))          // the stream got this far
        XCTAssertEqual(source.byteCount, 1_000)

        source.finish(reconcilingWith: complete)
        XCTAssertEqual(source.byteCount, complete.count,
                       "the 200-byte tail the stream never delivered must be recovered")
    }

    /// The ordinary case: the stream delivered everything before the request returned.
    /// Reconciling must be a no-op rather than duplicating the audio.
    func testSealingIsANoOpWhenTheStreamAlreadyDeliveredEverything() {
        let complete = chunk(0xAA, 1_200)
        let source = ChapterAudioSource(expectedBytes: 5_000)
        source.append(complete)

        source.finish(reconcilingWith: complete)
        XCTAssertEqual(source.byteCount, complete.count, "no bytes may be appended twice")
    }

    /// Defensive: the stream is a prefix of the complete audio by construction, but a
    /// source holding MORE than the request returned must not be truncated — throwing
    /// away audio already handed to `AVPlayer` would be worse than an inconsistency.
    func testSealingNeverTruncates() {
        let source = ChapterAudioSource(expectedBytes: 5_000)
        source.append(chunk(0xAA, 1_500))

        source.finish(reconcilingWith: chunk(0xAA, 1_000))
        XCTAssertEqual(source.byteCount, 1_500)
    }

    /// A chapter that streamed nothing at all still seals to the full audio.
    func testSealingRecoversEverythingWhenTheStreamDeliveredNothing() {
        let complete = chunk(0xCC, 800)
        let source = ChapterAudioSource(expectedBytes: 5_000)

        source.finish(reconcilingWith: complete)
        XCTAssertEqual(source.byteCount, complete.count)
    }
}
