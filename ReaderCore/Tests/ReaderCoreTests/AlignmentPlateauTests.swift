import XCTest
@testable import ReaderCore

final class AlignmentPlateauTests: XCTestCase {
    private func alignment(_ chars: [String], _ ends: [Double]) -> Alignment {
        Alignment(characters: chars,
                  startTimes: [0] + ends.dropLast(),
                  endTimes: ends)
    }

    func testAdvancingAlignmentHasNoUntimedTail() {
        let a = alignment(["あ", "い", "う"], [0.2, 0.4, 0.6])
        XCTAssertEqual(a.untimedTrailingCharacters, 0)
        XCTAssertEqual(a.untimedTrailingSpeech, 0)
    }

    func testFlatTailOfSpeechIsCounted() {
        let a = alignment(["あ", "い", "う", "え", "お"], [0.2, 0.4, 0.4, 0.4, 0.4])
        XCTAssertEqual(a.untimedTrailingCharacters, 3)
        XCTAssertEqual(a.untimedTrailingSpeech, 3)
    }

    func testFlatTailOfPunctuationCarriesNoSpeech() {
        let a = alignment(["あ", "い", "。", "\n", "」"], [0.2, 0.4, 0.4, 0.4, 0.4])
        XCTAssertEqual(a.untimedTrailingCharacters, 3)
        XCTAssertEqual(a.untimedTrailingSpeech, 0)
    }

    func testMixedFlatTailCountsOnlySpeechBearingCharacters() {
        let a = alignment(["あ", "、", "犬", "。", "A"], [0.2, 0.2, 0.2, 0.2, 0.2])
        XCTAssertEqual(a.untimedTrailingCharacters, 4)
        XCTAssertEqual(a.untimedTrailingSpeech, 2)
    }

    func testEmptyAlignmentReportsNothing() {
        let a = Alignment(characters: [], startTimes: [], endTimes: [])
        XCTAssertEqual(a.untimedTrailingCharacters, 0)
        XCTAssertEqual(a.untimedTrailingSpeech, 0)
    }

    func testSingleCharacterWithAPositiveEndIsTimed() {
        let a = alignment(["あ"], [0.2])
        XCTAssertEqual(a.untimedTrailingCharacters, 0)
        XCTAssertEqual(a.untimedTrailingSpeech, 0)
    }

    func testSingleCharacterOfSpeechEndingAtZeroIsUntimed() {
        let a = alignment(["あ"], [0.0])
        XCTAssertEqual(a.untimedTrailingCharacters, 1)
        XCTAssertEqual(a.untimedTrailingSpeech, 1)
    }

    func testSingleCharacterOfPunctuationEndingAtZeroCarriesNoSpeech() {
        let a = alignment(["。"], [0.0])
        XCTAssertEqual(a.untimedTrailingCharacters, 1)
        XCTAssertEqual(a.untimedTrailingSpeech, 0)
    }

    func testWhollyUntimedAlignmentCountsEveryCharacter() {
        let a = alignment(["あ", "い", "う"], [0.0, 0.0, 0.0])
        XCTAssertEqual(a.untimedTrailingCharacters, 3)
        XCTAssertEqual(a.untimedTrailingSpeech, 3)
    }

    func testMismatchedArrayLengthsReportNothing() {
        let a = Alignment(characters: ["あ", "い"], startTimes: [0], endTimes: [0.2])
        XCTAssertEqual(a.untimedTrailingCharacters, 0)
    }

    func testCapturedTruncationFromEleven_v3() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/truncation/v3-truncated-tail.json")
        let data = try Data(contentsOf: url)
        let a = try JSONDecoder().decode(Alignment.self, from: data)
        XCTAssertEqual(a.untimedTrailingCharacters, 32)
        XCTAssertEqual(a.untimedTrailingSpeech, 26)
    }
}
