import XCTest
@testable import ReaderCore

/// Guards the reading-progress writeback rules — in particular the bug where a
/// chapter played to its natural end never persisted as 読了, because
/// `AVAudioPlayer` resets its playhead to 0 on finish and the old code then bailed
/// on its "don't write a zero playhead" guard.
final class ReadingProgressResolverTests: XCTestCase {

    // MARK: - Completion (the regression)

    /// THE regression: a finished single-chapter doc must persist as complete
    /// (fraction 1.0 → 読了), independent of any reset playhead.
    func testCompletedSingleChapterIsFullyDone() {
        let p = ReadingProgressResolver.resolve(.completed, duration: 6.13,
                                                chapterIndex: 0, chapterCount: 1)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.fraction ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(p?.time ?? 0, 6.13, accuracy: 1e-9)
        XCTAssertEqual(p?.chapterIndex, 0)
    }

    /// Finishing the last chapter of a multi-chapter book is also 読了.
    func testCompletedLastChapterIsFullyDone() {
        let p = ReadingProgressResolver.resolve(.completed, duration: 30,
                                                chapterIndex: 2, chapterCount: 3)
        XCTAssertEqual(p?.fraction ?? 0, 1.0, accuracy: 1e-9)
    }

    /// Finishing a middle chapter advances the book-level fraction proportionally,
    /// not to 読了.
    func testCompletedMiddleChapterAdvancesBookFraction() {
        let p = ReadingProgressResolver.resolve(.completed, duration: 30,
                                                chapterIndex: 1, chapterCount: 4)
        XCTAssertEqual(p?.fraction ?? 0, 0.5, accuracy: 1e-9)   // (1 + 1) / 4
        XCTAssertEqual(p?.time ?? 0, 30, accuracy: 1e-9)
    }

    // MARK: - Interruption (the other guard)

    /// A never-played open (playhead still 0) must NOT be written — otherwise it
    /// clobbers a real saved position with zeros.
    func testInterruptedAtZeroPersistsNothing() {
        XCTAssertNil(ReadingProgressResolver.resolve(.interrupted(time: 0), duration: 6.13,
                                                     chapterIndex: 0, chapterCount: 1))
    }

    /// A pause/leave mid-chapter persists the real playhead and a proportional
    /// book-level fraction.
    func testInterruptedMidChapterPersistsPosition() {
        let p = ReadingProgressResolver.resolve(.interrupted(time: 3.0), duration: 6.0,
                                                chapterIndex: 0, chapterCount: 1)
        XCTAssertEqual(p?.time ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(p?.fraction ?? 0, 0.5, accuracy: 1e-9)
    }

    /// A playhead at/over duration clamps the within-chapter share to 1 (no
    /// fraction > the chapter's slice of the book).
    func testInterruptedAtEndClampsWithinChapter() {
        let p = ReadingProgressResolver.resolve(.interrupted(time: 99), duration: 10,
                                                chapterIndex: 0, chapterCount: 2)
        XCTAssertEqual(p?.fraction ?? 0, 0.5, accuracy: 1e-9)   // (0 + 1) / 2
    }

    // MARK: - Guards

    /// An unloaded chapter (duration 0) writes nothing for any event.
    func testZeroDurationPersistsNothing() {
        XCTAssertNil(ReadingProgressResolver.resolve(.completed, duration: 0,
                                                     chapterIndex: 0, chapterCount: 1))
        XCTAssertNil(ReadingProgressResolver.resolve(.interrupted(time: 5), duration: 0,
                                                     chapterIndex: 0, chapterCount: 1))
    }
}
