import XCTest
import ReaderCore
@testable import Reader

@MainActor
final class LibraryProgressTests: XCTestCase {
    private func item(_ lengths: [Int], progress: ReadingProgress) -> LibraryModel.Item {
        let doc = Document(title: "t",
                           chapters: lengths.map { Chapter(text: String(repeating: "あ", count: $0)) },
                           progress: progress)
        return LibraryModel.Item(document: doc, cached: false)
    }

    func testUntouchedBookShowsNoBarAndReadsUnread() {
        let i = item([1_000, 1_000], progress: ReadingProgress())
        XCTAssertEqual(i.fraction, 0, accuracy: 1e-9)
        XCTAssertEqual(i.statusLabel, L10n.statusUnread)
    }

    func testABarelyStartedBookNeverReadsUnreadWhileItsBarIsDrawn() {
        let i = item([20, 40_000], progress: ReadingProgress(chapterIndex: 1))
        XCTAssertGreaterThan(i.fraction, 0)
        XCTAssertEqual(i.statusLabel, "1%")
    }

    func testAlmostFinishedNeverReadsDone() {
        let i = item([9_960, 40], progress: ReadingProgress(chapterIndex: 1))
        XCTAssertLessThan(i.fraction, 1)
        XCTAssertEqual(i.statusLabel, "99%")
    }

    func testFinishingTheLastChapterReadsDone() {
        let i = item([1_000, 3_000],
                     progress: ReadingProgress(chapterIndex: 1, time: 42, duration: 42))
        XCTAssertEqual(i.fraction, 1, accuracy: 1e-9)
        XCTAssertEqual(i.statusLabel, L10n.statusDone)
    }

    func testMidBookReportsTheTextWeightedShare() {
        let i = item([2_500, 2_500, 5_000], progress: ReadingProgress(chapterIndex: 2))
        XCTAssertEqual(i.statusLabel, "50%")
    }

    func testFreeReadingOffsetMovesTheBar() {
        let unread = item([1_000, 1_000], progress: ReadingProgress(chapterIndex: 0))
        let scrolled = item([1_000, 1_000],
                            progress: ReadingProgress(chapterIndex: 0, charOffset: 500))
        XCTAssertEqual(unread.fraction, 0, accuracy: 1e-9)
        XCTAssertEqual(scrolled.fraction, 0.25, accuracy: 1e-9)
    }
}
