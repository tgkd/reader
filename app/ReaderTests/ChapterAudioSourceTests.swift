import XCTest
@testable import Reader

final class ChapterAudioSourceTests: XCTestCase {
    private func chunk(_ byte: UInt8, _ count: Int) -> Data {
        Data(repeating: byte, count: count)
    }

    func testSealingRecoversATailTheStreamNeverDelivered() {
        let complete = chunk(0xAA, 1_000) + chunk(0xBB, 200)
        let source = ChapterAudioSource(expectedBytes: 5_000)
        source.append(complete.prefix(1_000))
        XCTAssertEqual(source.byteCount, 1_000)

        source.finish(reconcilingWith: complete)
        XCTAssertEqual(source.byteCount, complete.count,
                       "the 200-byte tail the stream never delivered must be recovered")
    }

    func testSealingIsANoOpWhenTheStreamAlreadyDeliveredEverything() {
        let complete = chunk(0xAA, 1_200)
        let source = ChapterAudioSource(expectedBytes: 5_000)
        source.append(complete)

        source.finish(reconcilingWith: complete)
        XCTAssertEqual(source.byteCount, complete.count, "no bytes may be appended twice")
    }

    func testSealingNeverTruncates() {
        let source = ChapterAudioSource(expectedBytes: 5_000)
        source.append(chunk(0xAA, 1_500))

        source.finish(reconcilingWith: chunk(0xAA, 1_000))
        XCTAssertEqual(source.byteCount, 1_500)
    }

    func testSealingRecoversEverythingWhenTheStreamDeliveredNothing() {
        let complete = chunk(0xCC, 800)
        let source = ChapterAudioSource(expectedBytes: 5_000)

        source.finish(reconcilingWith: complete)
        XCTAssertEqual(source.byteCount, complete.count)
    }
}
