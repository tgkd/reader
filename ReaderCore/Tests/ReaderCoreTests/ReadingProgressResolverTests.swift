import XCTest
@testable import ReaderCore

final class ReadingProgressResolverTests: XCTestCase {
    func testCompletedSingleChapterIsFullyDone() {
        let p = ReadingProgressResolver.resolve(.completed, duration: 6.13,
                                                chapterIndex: 0, chapterCount: 1)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.fraction ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(p?.time ?? 0, 6.13, accuracy: 1e-9)
        XCTAssertEqual(p?.chapterIndex, 0)
    }

    func testCompletedLastChapterIsFullyDone() {
        let p = ReadingProgressResolver.resolve(.completed, duration: 30,
                                                chapterIndex: 2, chapterCount: 3)
        XCTAssertEqual(p?.fraction ?? 0, 1.0, accuracy: 1e-9)
    }

    func testCompletedMiddleChapterAdvancesBookFraction() {
        let p = ReadingProgressResolver.resolve(.completed, duration: 30,
                                                chapterIndex: 1, chapterCount: 4)
        XCTAssertEqual(p?.fraction ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(p?.time ?? 0, 30, accuracy: 1e-9)
    }

    func testInterruptedAtZeroPersistsNothing() {
        XCTAssertNil(ReadingProgressResolver.resolve(.interrupted(time: 0), duration: 6.13,
                                                     chapterIndex: 0, chapterCount: 1))
    }

    func testInterruptedMidChapterPersistsPosition() {
        let p = ReadingProgressResolver.resolve(.interrupted(time: 3.0), duration: 6.0,
                                                chapterIndex: 0, chapterCount: 1)
        XCTAssertEqual(p?.time ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(p?.fraction ?? 0, 0.5, accuracy: 1e-9)
    }

    func testInterruptedAtEndClampsWithinChapter() {
        let p = ReadingProgressResolver.resolve(.interrupted(time: 99), duration: 10,
                                                chapterIndex: 0, chapterCount: 2)
        XCTAssertEqual(p?.fraction ?? 0, 0.5, accuracy: 1e-9)
    }

    func testZeroDurationPersistsNothing() {
        XCTAssertNil(ReadingProgressResolver.resolve(.completed, duration: 0,
                                                     chapterIndex: 0, chapterCount: 1))
        XCTAssertNil(ReadingProgressResolver.resolve(.interrupted(time: 5), duration: 0,
                                                     chapterIndex: 0, chapterCount: 1))
    }
}
