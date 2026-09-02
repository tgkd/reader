import XCTest
@testable import ReaderCore

final class AlignmentDescribesTests: XCTestCase {
    private let text = "吾輩は猫"

    private func alignment(_ text: String,
                           starts: [Double]? = nil,
                           ends: [Double]? = nil) -> Alignment {
        let chars = text.map(String.init)
        let e = ends ?? (1...chars.count).map { Double($0) * 0.5 }
        let s = starts ?? ([0.0] + e.dropLast())
        return Alignment(characters: chars, startTimes: s, endTimes: e)
    }

    func testAcceptsAnAlignmentThatReproducesTheTextAndEndsWithTheAudio() {
        XCTAssertTrue(alignment(text).describes(text, audioSeconds: 2.0))
        XCTAssertTrue(alignment(text).describes(text, audioSeconds: 2.9))
        XCTAssertTrue(alignment(text).describes(text, audioSeconds: 1.1))
    }

    func testRejectsAnAlignmentOfDifferentText() {
        XCTAssertFalse(alignment("吾輩は犬").describes(text, audioSeconds: 2.0))
        XCTAssertFalse(alignment("吾輩は").describes(text, audioSeconds: 2.0))
    }

    func testRejectsAnAlignmentTooFarFromTheAudio() {
        XCTAssertFalse(alignment(text).describes(text, audioSeconds: 3.5))
        XCTAssertFalse(alignment(text).describes(text, audioSeconds: 0.5))
    }

    func testRejectsStartsThatRunBackwards() {
        let a = alignment(text, starts: [0, 0.5, 0.4, 1.5], ends: [0.5, 1.0, 1.5, 2.0])
        XCTAssertFalse(a.describes(text, audioSeconds: 2.0))
    }

    func testRejectsACharacterThatEndsBeforeItStarts() {
        let a = alignment(text, starts: [0, 0.5, 1.0, 1.5], ends: [0.5, 1.0, 0.9, 2.0])
        XCTAssertFalse(a.describes(text, audioSeconds: 2.0))
    }

    func testRejectsATerminalRunOfUntimedSpeech() {
        let a = alignment(text, starts: [0, 0.5, 1.0, 1.0], ends: [0.5, 1.0, 1.0, 1.0])
        XCTAssertFalse(a.describes(text, audioSeconds: 1.2))
    }

    func testRejectsMismatchedArrayLengths() {
        let a = Alignment(characters: ["吾", "輩", "は", "猫"],
                          startTimes: [0, 0.5, 1.0], endTimes: [0.5, 1.0, 1.5, 2.0])
        XCTAssertFalse(a.describes(text, audioSeconds: 2.0))
    }

    func testRejectsMultiCharacterElementsAndAnEmptyAlignment() {
        let a = Alignment(characters: ["吾輩", "は", "猫"],
                          startTimes: [0, 1.0, 1.5], endTimes: [1.0, 1.5, 2.0])
        XCTAssertFalse(a.describes(text, audioSeconds: 2.0))
        XCTAssertFalse(Alignment(characters: [], startTimes: [], endTimes: [])
            .describes("", audioSeconds: 0))
    }

    func testRejectsNonFiniteTimes() {
        let a = alignment(text, starts: [0, 0.5, 1.0, 1.5], ends: [0.5, 1.0, 1.5, .nan])
        XCTAssertFalse(a.describes(text, audioSeconds: 2.0))
    }

    func testDecodesTheWorkersTrailerLine() throws {
        let line = """
        {"forced_alignment":{"characters":["吾","輩"],\
        "character_start_times_seconds":[0.06,0.5],\
        "character_end_times_seconds":[0.5,0.56]},"forced_alignment_loss":2.03}
        """
        let trailer = try JSONDecoder().decode(AlignmentTrailer.self, from: Data(line.utf8))
        XCTAssertEqual(trailer.forcedAlignment.characters, ["吾", "輩"])
        XCTAssertEqual(trailer.forcedAlignment.endTimes, [0.5, 0.56])
        XCTAssertEqual(trailer.loss, 2.03)
        XCTAssertTrue(trailer.forcedAlignment.describes("吾輩", audioSeconds: 0.6))
    }

    func testDecodesATrailerWithoutALoss() throws {
        let line = """
        {"forced_alignment":{"characters":["吾"],\
        "character_start_times_seconds":[0.0],"character_end_times_seconds":[0.5]}}
        """
        let trailer = try JSONDecoder().decode(AlignmentTrailer.self, from: Data(line.utf8))
        XCTAssertNil(trailer.loss)
        XCTAssertEqual(trailer.forcedAlignment.characters, ["吾"])
    }

    func testAnAudioChunkIsNotATrailer() {
        let line = """
        {"audio_base64":"AAA=","alignment":{"characters":["吾"],\
        "character_start_times_seconds":[0.0],"character_end_times_seconds":[0.5]}}
        """
        XCTAssertNil(try? JSONDecoder().decode(AlignmentTrailer.self, from: Data(line.utf8)))
    }
}
