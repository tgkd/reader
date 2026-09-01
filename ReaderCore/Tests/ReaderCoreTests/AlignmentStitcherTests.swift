import XCTest
@testable import ReaderCore

final class AlignmentStitcherTests: XCTestCase {
    private func segment(chars: [String], starts: [Double], ends: [Double],
                         audio: [UInt8], text: String) -> SynthesizedAudio {
        SynthesizedAudio(audio: Data(audio),
                         alignment: Alignment(characters: chars, startTimes: starts, endTimes: ends),
                         text: text)
    }

    func testSingleSegmentReturnedUnchanged() {
        let s = segment(chars: ["あ"], starts: [0], ends: [0.5], audio: [1, 2, 3], text: "あ")
        let out = AlignmentStitcher.stitch([s])
        XCTAssertEqual(out, s)
    }

    func testConcatenatesCharactersTextAndAudio() {
        let a = segment(chars: ["A", "B"], starts: [0.0, 0.4], ends: [0.4, 0.8],
                        audio: [0x01, 0x02], text: "AB")
        let b = segment(chars: ["C"], starts: [0.0], ends: [0.6],
                        audio: [0x03, 0x04, 0x05], text: "C")
        let out = AlignmentStitcher.stitch([a, b])

        XCTAssertEqual(out.alignment.characters, ["A", "B", "C"])
        XCTAssertEqual(out.text, "ABC")
        XCTAssertEqual(out.audio, Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        XCTAssertEqual(out.alignment.characters.count, out.alignment.startTimes.count)
        XCTAssertEqual(out.alignment.characters.count, out.alignment.endTimes.count)
    }

    private func silence(seconds: Double) -> [UInt8] {
        [UInt8](repeating: 0, count: Int(seconds * NarrationAudio.mp3BytesPerSecond))
    }

    func testSecondSegmentTimesOffsetByFirstAudioDuration() {
        let a = segment(chars: ["A", "B"], starts: [0.0, 0.4], ends: [0.4, 0.8],
                        audio: silence(seconds: 0.8), text: "AB")
        let b = segment(chars: ["C", "D"], starts: [0.0, 0.5], ends: [0.5, 1.0],
                        audio: silence(seconds: 1.0), text: "CD")
        let out = AlignmentStitcher.stitch([a, b])

        XCTAssertEqual(out.alignment.startTimes, [0.0, 0.4, 0.8, 1.3])
        XCTAssertEqual(out.alignment.endTimes, [0.4, 0.8, 1.3, 1.8])
    }

    func testTrailingAudioBeyondTheAlignmentStillOffsetsTheNextSegment() {
        let a = segment(chars: ["A", "B"], starts: [0.0, 0.4], ends: [0.4, 0.8],
                        audio: silence(seconds: 2.68), text: "AB")
        let b = segment(chars: ["C"], starts: [0.0], ends: [0.5],
                        audio: silence(seconds: 0.5), text: "C")
        let out = AlignmentStitcher.stitch([a, b])

        XCTAssertEqual(out.alignment.startTimes[2], 2.68, accuracy: 1e-9)
        XCTAssertEqual(out.alignment.endTimes[2], 3.18, accuracy: 1e-9)
    }

    func testAlignmentOverrunningItsAudioKeepsTheJoinMonotonic() {
        let a = segment(chars: ["A"], starts: [0.0], ends: [1.5],
                        audio: silence(seconds: 0.8), text: "A")
        let b = segment(chars: ["B"], starts: [0.0], ends: [0.5],
                        audio: silence(seconds: 0.5), text: "B")
        let out = AlignmentStitcher.stitch([a, b])

        XCTAssertEqual(out.alignment.startTimes[1], 1.5, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(out.alignment.startTimes[1], out.alignment.endTimes[0])
    }

    func testTimesAreMonotonicNonDecreasingAcrossJoin() {
        let segs = (0..<4).map { i in
            segment(chars: ["x", "y"], starts: [0.0, 0.3], ends: [0.3, 0.7],
                    audio: [UInt8(i)], text: "xy")
        }
        let out = AlignmentStitcher.stitch(segs)
        for k in out.alignment.startTimes.indices.dropFirst() {
            XCTAssertGreaterThanOrEqual(out.alignment.startTimes[k], out.alignment.startTimes[k - 1],
                                        "non-monotonic start at \(k)")
        }
        XCTAssertEqual(out.alignment.characters.count, 8)
    }
}
