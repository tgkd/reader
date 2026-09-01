import XCTest
@testable import ReaderCore

final class TimelineRefreshPolicyTests: XCTestCase {
    private let policy = TimelineRefreshPolicy(batchSeconds: 2.0, safetySeconds: 1.5)

    func testNoNewAlignmentNeverRebuilds() {
        XCTAssertFalse(policy.shouldRebuild(alignedTime: 10, builtTo: 10,
                                            timedExtent: 10, playhead: 9.9, rate: 1.5))
        XCTAssertFalse(policy.shouldRebuild(alignedTime: 10, builtTo: 10,
                                            timedExtent: 10, playhead: 20, rate: 1.0))
    }

    func testFullBatchRebuildsAtAnyRate() {
        for rate in [0.75, 1.0, 1.25, 1.5] {
            XCTAssertTrue(policy.shouldRebuild(alignedTime: 12, builtTo: 10,
                                               timedExtent: 12, playhead: 0, rate: rate))
        }
    }

    func testSubThresholdChunkWaitsWhileRunwayIsAmple() {
        XCTAssertFalse(policy.shouldRebuild(alignedTime: 11, builtTo: 10,
                                            timedExtent: 10, playhead: 4, rate: 1.0))
    }

    func testShortRunwayForcesRebuildOnSubThresholdChunk() {
        XCTAssertTrue(policy.shouldRebuild(alignedTime: 11, builtTo: 10,
                                           timedExtent: 10, playhead: 9, rate: 1.0))
    }

    func testFasterRateForcesRebuildEarlier() {
        XCTAssertFalse(policy.shouldRebuild(alignedTime: 11, builtTo: 10,
                                           timedExtent: 10, playhead: 8.2, rate: 1.0))
        XCTAssertTrue(policy.shouldRebuild(alignedTime: 11, builtTo: 10,
                                           timedExtent: 10, playhead: 8.2, rate: 1.5))
    }

    func testSlowerRateStretchesTheRunway() {
        XCTAssertTrue(policy.shouldRebuild(alignedTime: 11, builtTo: 10,
                                           timedExtent: 10, playhead: 8.8, rate: 1.0))
        XCTAssertFalse(policy.shouldRebuild(alignedTime: 11, builtTo: 10,
                                            timedExtent: 10, playhead: 8.8, rate: 0.75))
    }

    func testPlayheadPastTheFrontierForcesRebuild() {
        XCTAssertTrue(policy.shouldRebuild(alignedTime: 10.5, builtTo: 10,
                                           timedExtent: 10, playhead: 10.4, rate: 1.0))
    }

    func testStalledClockOnlyRebuildsOnAFullBatch() {
        XCTAssertFalse(policy.shouldRebuild(alignedTime: 11, builtTo: 10,
                                            timedExtent: 10, playhead: 10, rate: 0))
        XCTAssertTrue(policy.shouldRebuild(alignedTime: 12, builtTo: 10,
                                           timedExtent: 10, playhead: 10, rate: 0))
    }
}
