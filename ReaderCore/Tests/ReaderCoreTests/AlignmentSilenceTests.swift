import XCTest
@testable import ReaderCore

final class AlignmentSilenceTests: XCTestCase {
    private func alignment(_ chars: [String], _ starts: [Double], _ ends: [Double]) -> Alignment {
        Alignment(characters: chars, startTimes: starts, endTimes: ends)
    }

    func testALongPunctuationCharacterIsASilence() {
        let a = alignment(["吾", "。", "輩"], [0, 0.5, 2.0], [0.5, 2.0, 2.5])
        XCTAssertEqual(a.silences(minimumSeconds: 0.5), [0.5...2.0])
    }

    func testAGapBetweenCharactersIsASilence() {
        let a = alignment(["吾", "輩"], [0, 1.5], [0.5, 2.0])
        XCTAssertEqual(a.silences(minimumSeconds: 0.5), [0.5...1.5])
    }

    func testAdjacentPunctuationGapAndWhitespaceMergeIntoOneSilence() {
        let a = alignment(["吾", "。", "\n", "輩"], [0, 0.5, 0.9, 1.6], [0.5, 0.8, 1.2, 2.0])
        XCTAssertEqual(a.silences(minimumSeconds: 0.5), [0.5...1.6])
    }

    func testShortPausesAreNotSilences() {
        let a = alignment(["吾", "、", "輩"], [0, 0.5, 0.8], [0.5, 0.8, 1.2])
        XCTAssertEqual(a.silences(minimumSeconds: 0.5), [])
        XCTAssertNil(a.nextSilence(after: 0, minimumSeconds: 0.5))
    }

    func testASpokenCharacterIsNeverASilenceHoweverLong() {
        let a = alignment(["吾", "輩"], [0, 3.0], [3.0, 3.5])
        XCTAssertEqual(a.silences(minimumSeconds: 0.5), [])
    }

    func testNextSilenceSkipsThoseAlreadyOver() {
        let a = alignment(["吾", "。", "輩", "。", "猫"],
                          [0, 0.5, 1.5, 2.0, 3.0], [0.5, 1.5, 2.0, 3.0, 3.5])
        XCTAssertEqual(a.nextSilence(after: 1.6, minimumSeconds: 0.5), 2.0...3.0)
        XCTAssertEqual(a.nextSilence(after: 1.0, minimumSeconds: 0.5), 0.5...1.5)
        XCTAssertNil(a.nextSilence(after: 3.2, minimumSeconds: 0.5))
    }

    func testMismatchedArraysYieldNothing() {
        let a = Alignment(characters: ["吾", "。"], startTimes: [0], endTimes: [0.5, 2.0])
        XCTAssertEqual(a.silences(minimumSeconds: 0.5), [])
    }
}
