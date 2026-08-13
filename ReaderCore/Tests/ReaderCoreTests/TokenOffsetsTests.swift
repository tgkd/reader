import XCTest
@testable import ReaderCore

final class TokenOffsetsTests: XCTestCase {
    private func spans(_ surfaces: [String]) -> [TokenSpan] {
        surfaces.enumerated().map {
            TokenSpan(index: $0.offset, surface: $0.element, reading: nil,
                      start: 0, end: 0, matchedChars: $0.element.count)
        }
    }

    func testOffsetIsThePrefixSumOfSurfaces() {
        let s = spans(["吾輩", "は", "猫", "である"])
        XCTAssertEqual(TokenOffsets.charOffset(ofToken: 0, in: s), 0)
        XCTAssertEqual(TokenOffsets.charOffset(ofToken: 1, in: s), 2)
        XCTAssertEqual(TokenOffsets.charOffset(ofToken: 2, in: s), 3)
        XCTAssertEqual(TokenOffsets.charOffset(ofToken: 3, in: s), 4)
    }

    func testRoundTripsThroughEveryTokenBoundary() {
        let s = spans(["吾輩", "は", "猫", "である", "。"])
        for i in s.indices {
            let offset = TokenOffsets.charOffset(ofToken: i, in: s)
            XCTAssertEqual(TokenOffsets.token(atCharOffset: offset, in: s), i, "token \(i)")
        }
    }

    func testOffsetInsideATokenResolvesToThatToken() {
        let s = spans(["吾輩", "は", "である"])
        XCTAssertEqual(TokenOffsets.token(atCharOffset: 1, in: s), 0)
        XCTAssertEqual(TokenOffsets.token(atCharOffset: 3, in: s), 2)
        XCTAssertEqual(TokenOffsets.token(atCharOffset: 5, in: s), 2)
    }

    func testOffsetPastTheEndClampsToTheLastToken() {
        let s = spans(["吾輩", "は"])
        XCTAssertEqual(TokenOffsets.token(atCharOffset: 999, in: s), 1)
    }

    func testEmptySpansHaveNoToken() {
        XCTAssertNil(TokenOffsets.token(atCharOffset: 0, in: []))
        XCTAssertEqual(TokenOffsets.charOffset(ofToken: 3, in: []), 0)
    }

    func testGapTokensCountTowardTheOffset() {
        let s = spans(["一行目", "\n", "二行目"])
        XCTAssertEqual(TokenOffsets.charOffset(ofToken: 2, in: s), 4)
        XCTAssertEqual(TokenOffsets.token(atCharOffset: 4, in: s), 2)
    }
}
