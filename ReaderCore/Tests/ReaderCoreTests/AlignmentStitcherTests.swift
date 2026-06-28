import XCTest
@testable import ReaderCore

/// `AlignmentStitcher.stitch` glues chunked segment synthesis back into one
/// continuous chapter. These pin the timeline math (per-segment offset by spoken
/// length, monotonic non-decreasing across the join) and the concatenation
/// invariants (characters/text/audio all reconstruct in order) that keep the
/// stitched result indistinguishable from an unchunked one for the reader.
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

    func testSecondSegmentTimesOffsetByFirstSpokenLength() {
        let a = segment(chars: ["A", "B"], starts: [0.0, 0.4], ends: [0.4, 0.8],
                        audio: [0], text: "AB")      // spoken length = max end = 0.8
        let b = segment(chars: ["C", "D"], starts: [0.0, 0.5], ends: [0.5, 1.0],
                        audio: [0], text: "CD")
        let out = AlignmentStitcher.stitch([a, b])

        XCTAssertEqual(out.alignment.startTimes, [0.0, 0.4, 0.8, 1.3])
        XCTAssertEqual(out.alignment.endTimes, [0.4, 0.8, 1.3, 1.8])
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
        // The whole stitched timeline drives SpanTimeline cleanly.
        XCTAssertEqual(out.alignment.characters.count, 8)
    }
}
