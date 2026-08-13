import XCTest
@testable import ReaderCore

final class ReadingProgressResolverTests: XCTestCase {
    func testCompletedRecordsTheFullChapter() {
        let p = ReadingProgressResolver.resolve(.completed, duration: 6.13, chapterIndex: 0)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.time ?? 0, 6.13, accuracy: 1e-9)
        XCTAssertEqual(p?.duration ?? 0, 6.13, accuracy: 1e-9)
        XCTAssertEqual(p?.chapterIndex, 0)
    }

    func testInterruptedAtZeroPersistsNothing() {
        XCTAssertNil(ReadingProgressResolver.resolve(.interrupted(time: 0), duration: 6.13,
                                                     chapterIndex: 0))
    }

    func testInterruptedMidChapterPersistsPosition() {
        let p = ReadingProgressResolver.resolve(.interrupted(time: 3.0), duration: 6.0,
                                                chapterIndex: 2)
        XCTAssertEqual(p?.time ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(p?.duration ?? 0, 6.0, accuracy: 1e-9)
        XCTAssertEqual(p?.chapterIndex, 2)
    }

    func testInterruptedPastTheEndClampsToDuration() {
        let p = ReadingProgressResolver.resolve(.interrupted(time: 99), duration: 10,
                                                chapterIndex: 0)
        XCTAssertEqual(p?.time ?? 0, 10, accuracy: 1e-9)
    }

    func testZeroDurationPersistsNothing() {
        XCTAssertNil(ReadingProgressResolver.resolve(.completed, duration: 0, chapterIndex: 0))
        XCTAssertNil(ReadingProgressResolver.resolve(.interrupted(time: 5), duration: 0,
                                                     chapterIndex: 0))
    }
}

final class DocumentReadFractionTests: XCTestCase {
    private func document(_ lengths: [Int], progress: ReadingProgress) -> Document {
        Document(title: "t",
                 chapters: lengths.map { Chapter(text: String(repeating: "あ", count: $0)) },
                 progress: progress)
    }

    func testShortChaptersDoNotWeighTheSameAsLongOnes() {
        let doc = document([200, 3_800], progress: ReadingProgress(chapterIndex: 1))
        XCTAssertEqual(doc.readFraction, 0.05, accuracy: 1e-9)
    }

    func testChapterCountWeightingWouldHaveSaidHalf() {
        let doc = document([200, 3_800], progress: ReadingProgress(chapterIndex: 1))
        XCTAssertNotEqual(doc.readFraction, 0.5, accuracy: 0.01)
    }

    func testWithinChapterUsesTheStoredDuration() {
        let doc = document([1_000, 1_000],
                           progress: ReadingProgress(chapterIndex: 1, time: 15, duration: 30))
        XCTAssertEqual(doc.readFraction, 0.75, accuracy: 1e-9)
    }

    func testFinishingTheLastChapterReadsAsComplete() {
        let doc = document([1_000, 3_000],
                           progress: ReadingProgress(chapterIndex: 1, time: 42, duration: 42))
        XCTAssertEqual(doc.readFraction, 1.0, accuracy: 1e-9)
    }

    func testLegacyProgressWithoutDurationFallsBackToChapterStart() {
        let doc = document([1_000, 1_000], progress: ReadingProgress(chapterIndex: 1, time: 15))
        XCTAssertEqual(doc.readFraction, 0.5, accuracy: 1e-9)
    }

    func testUnreadBookIsZero() {
        let doc = document([1_000, 1_000], progress: ReadingProgress())
        XCTAssertEqual(doc.readFraction, 0, accuracy: 1e-9)
    }

    func testOutOfRangeChapterIndexIsClamped() {
        let doc = document([1_000, 1_000], progress: ReadingProgress(chapterIndex: 9))
        XCTAssertEqual(doc.readFraction, 0.5, accuracy: 1e-9)
    }

    func testEmptyDocumentIsZero() {
        XCTAssertEqual(Document(title: "t", chapters: []).readFraction, 0, accuracy: 1e-9)
    }

    func testDecodingLegacyProgressKeepsChapterAndTime() throws {
        let legacy = Data("""
        {"chapterIndex":3,"time":12.5,"fraction":0.75}
        """.utf8)
        let p = try JSONDecoder().decode(ReadingProgress.self, from: legacy)
        XCTAssertEqual(p.chapterIndex, 3)
        XCTAssertEqual(p.time, 12.5, accuracy: 1e-9)
        XCTAssertEqual(p.duration, 0, accuracy: 1e-9)
    }
}
