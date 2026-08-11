import XCTest
@testable import Reader

final class ChapterAudioSourceTests: XCTestCase {
    private func chunk(_ byte: UInt8, _ count: Int) -> Data {
        Data(repeating: byte, count: count)
    }

    func testAppendedChunksAccumulate() {
        let source = ChapterAudioSource(expectedBytes: 5_000)
        source.append(chunk(0xAA, 1_000))
        source.append(chunk(0xBB, 200))

        XCTAssertEqual(source.byteCount, 1_200)
    }

    func testSealingKeepsEveryByteTheStreamDelivered() {
        let source = ChapterAudioSource(expectedBytes: 5_000)
        source.append(chunk(0xAA, 1_200))
        source.finish()

        XCTAssertEqual(source.byteCount, 1_200)
    }

    // MARK: - What a read can be answered with

    func testServesWhatHasArrivedAndKeepsTheRequestOpen() {
        XCTAssertEqual(
            ChapterAudioSource.read(offset: 0, requestedOffset: 0, requestedLength: 100,
                                    available: 40, isComplete: false),
            .send(count: 40, thenFinish: false),
            "the rest of this range is still being generated")
    }

    func testServesAFullRangeAndClosesTheRequest() {
        XCTAssertEqual(
            ChapterAudioSource.read(offset: 0, requestedOffset: 0, requestedLength: 100,
                                    available: 400, isComplete: false),
            .send(count: 100, thenFinish: true))
    }

    func testAShortReadClosesOnceTheResourceIsSealed() {
        XCTAssertEqual(
            ChapterAudioSource.read(offset: 360, requestedOffset: 360, requestedLength: 100,
                                    available: 400, isComplete: true),
            .send(count: 40, thenFinish: true),
            "there will never be more, so the reader must not be left waiting for it")
    }

    func testAReadPastTheEndOfASealedResourceIsFinishedNotDropped() {
        XCTAssertEqual(
            ChapterAudioSource.read(offset: 500, requestedOffset: 500, requestedLength: 100,
                                    available: 400, isComplete: true),
            .finish,
            "the advertised length is a guess that runs long, so AVFoundation reads into a tail "
                + "that never existed; dropping that request leaves the player waiting forever "
                + "and the chapter never reports that it ended")
    }

    func testAReadExactlyAtTheSealedEndFinishesWithNoBytes() {
        XCTAssertEqual(
            ChapterAudioSource.read(offset: 400, requestedOffset: 400, requestedLength: 100,
                                    available: 400, isComplete: true),
            .send(count: 0, thenFinish: true))
    }

    func testAReadPastTheFrontierOfAGrowingResourceWaits() {
        XCTAssertEqual(
            ChapterAudioSource.read(offset: 500, requestedOffset: 500, requestedLength: 100,
                                    available: 400, isComplete: false),
            .wait,
            "those bytes have not been generated yet, but they are coming")
    }

    func testAPartlyDrainedRequestAsksOnlyForWhatItStillNeeds() {
        XCTAssertEqual(
            ChapterAudioSource.read(offset: 430, requestedOffset: 400, requestedLength: 100,
                                    available: 500, isComplete: false),
            .send(count: 70, thenFinish: true),
            "30 bytes were already handed over, so 70 completes the range")
    }
}
