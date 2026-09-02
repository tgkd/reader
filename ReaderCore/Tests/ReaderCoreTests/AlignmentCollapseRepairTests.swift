import XCTest
@testable import ReaderCore

final class AlignmentCollapseRepairTests: XCTestCase {
    private func alignment(_ text: String, durations: [Double]) -> Alignment {
        var starts: [Double] = []
        var ends: [Double] = []
        var t = 0.0
        for d in durations {
            starts.append(t)
            t += d
            ends.append(t)
        }
        return Alignment(characters: text.map(String.init), startTimes: starts, endTimes: ends)
    }

    private let head = "吾輩は猫。"
    private let collapsed = "名前はまだ無いのだ"
    private let tail = "どこで生れたか。"

    private func collapsedChapter(runSeconds: Double = 0.01) -> Alignment {
        let durations = Array(repeating: 0.2, count: head.count)
            + Array(repeating: runSeconds, count: collapsed.count)
            + Array(repeating: 0.2, count: tail.count)
        return alignment(head + collapsed + tail, durations: durations)
    }

    func testFindsAnInteriorRunOfCollapsedSpeech() {
        let a = collapsedChapter()
        XCTAssertEqual(a.collapsedSpeechRuns, [head.count..<(head.count + collapsed.count)])
    }

    func testAShortCollapsedRunIsNotAFinding() {
        let a = alignment("吾輩は猫。名前はまだ。", durations: [0.2, 0.2, 0.2, 0.2, 0.2, 0.01, 0.01, 0.01, 0.01, 0.01, 0.2])
        XCTAssertEqual(a.collapsedSpeechRuns, [])
    }

    func testTheTerminalPlateauIsNotACollapsedRun() {
        let a = Alignment(characters: "吾輩は猫であるあいう".map(String.init),
                          startTimes: [0, 0.2, 0.4, 0.6, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8],
                          endTimes: [0.2, 0.4, 0.6, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8])
        XCTAssertEqual(a.collapsedSpeechRuns, [])
        XCTAssertEqual(a.untimedTrailingSpeech, 6)
        XCTAssertEqual(a.repairingCollapsedRuns(audioSeconds: 4.0), a)
    }

    func testRepairStretchesTheRunAndShiftsEverythingAfter() {
        let a = collapsedChapter()
        let audio = (a.endTimes.last ?? 0) + 1.9
        let r = a.repairingCollapsedRuns(audioSeconds: audio)
        XCTAssertEqual(r.characters, a.characters)
        XCTAssertEqual(r.endTimes.last ?? 0, audio, accuracy: 1e-9)
        for k in 0..<head.count {
            XCTAssertEqual(r.startTimes[k], a.startTimes[k])
            XCTAssertEqual(r.endTimes[k], a.endTimes[k])
        }
        let runEnd = head.count + collapsed.count
        for k in runEnd..<a.characters.count {
            XCTAssertEqual(r.startTimes[k], a.startTimes[k] + 1.9, accuracy: 1e-9)
            XCTAssertEqual(r.endTimes[k], a.endTimes[k] + 1.9, accuracy: 1e-9)
        }
        let perCharacter = 1.9 / Double(collapsed.count)
        for k in head.count..<runEnd {
            XCTAssertEqual(r.endTimes[k] - r.startTimes[k], perCharacter, accuracy: 1e-9)
        }
        for k in 1..<r.characters.count {
            XCTAssertGreaterThanOrEqual(r.startTimes[k], r.startTimes[k - 1] - 1e-9)
            XCTAssertGreaterThanOrEqual(r.endTimes[k], r.startTimes[k] - 1e-9)
        }
    }

    func testRepairIsANoOpWhenTheAudioIsDescribed() {
        let a = collapsedChapter()
        XCTAssertEqual(a.repairingCollapsedRuns(audioSeconds: (a.endTimes.last ?? 0) + 0.05), a)
    }

    func testUnexplainedTrailingAudioLeavesTheAlignmentAlone() {
        let a = alignment("吾輩は猫である。", durations: Array(repeating: 0.2, count: 8))
        XCTAssertEqual(a.collapsedSpeechRuns, [])
        XCTAssertEqual(a.repairingCollapsedRuns(audioSeconds: 10), a)
    }

    func testRepairIsIdempotent() {
        let a = collapsedChapter()
        let audio = (a.endTimes.last ?? 0) + 1.9
        let once = a.repairingCollapsedRuns(audioSeconds: audio)
        XCTAssertEqual(once.repairingCollapsedRuns(audioSeconds: audio), once)
    }

    func testTwoRunsShareTheMissingTimeByLength() {
        let text = head + collapsed + tail + collapsed + tail
        let durations = Array(repeating: 0.2, count: head.count)
            + Array(repeating: 0.01, count: collapsed.count)
            + Array(repeating: 0.2, count: tail.count)
            + Array(repeating: 0.01, count: collapsed.count)
            + Array(repeating: 0.2, count: tail.count)
        let a = alignment(text, durations: durations)
        XCTAssertEqual(a.collapsedSpeechRuns.count, 2)
        let audio = (a.endTimes.last ?? 0) + 3.0
        let r = a.repairingCollapsedRuns(audioSeconds: audio)
        XCTAssertEqual(r.endTimes.last ?? 0, audio, accuracy: 1e-9)
        let firstRunEnd = head.count + collapsed.count
        XCTAssertEqual(r.startTimes[firstRunEnd], a.startTimes[firstRunEnd] + 1.5, accuracy: 1e-9)
    }

    func testPauseAttributionSeparatesSpeechFromPunctuation() {
        let a = alignment("吾輩は。猫、", durations: [0.1, 1.0, 0.1, 0.9, 0.1, 1.2])
        XCTAssertEqual(a.pauseAttribution(), Alignment.PauseAttribution(onSpeech: 1, onPunctuation: 2))
    }

    func testCapturedCollapseFromEleven_v3() throws {
        struct Capture: Decodable {
            let characters: [String]
            let starts: [Double]
            let ends: [Double]
            let audioSeconds: Double
            enum CodingKeys: String, CodingKey {
                case characters
                case starts = "character_start_times_seconds"
                case ends = "character_end_times_seconds"
                case audioSeconds = "audio_seconds"
            }
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/collapse/v3-collapsed-phrase.json")
        let c = try JSONDecoder().decode(Capture.self, from: Data(contentsOf: url))
        let a = Alignment(characters: c.characters, startTimes: c.starts, endTimes: c.ends)
        XCTAssertEqual(a.untimedTrailingCharacters, 0)
        XCTAssertEqual(a.collapsedSpeechRuns, [1115..<1129])
        XCTAssertEqual(c.audioSeconds - (a.endTimes.last ?? 0), 1.88, accuracy: 0.001)

        let r = a.repairingCollapsedRuns(audioSeconds: c.audioSeconds)
        XCTAssertEqual(r.endTimes.last ?? 0, c.audioSeconds, accuracy: 1e-6)
        XCTAssertEqual(r.startTimes[1162] - a.startTimes[1162], 1.88, accuracy: 0.001)
        XCTAssertEqual(r.startTimes[1489] - a.startTimes[1489], 1.88, accuracy: 0.001)
        XCTAssertEqual(r.startTimes[1100], a.startTimes[1100])
        XCTAssertEqual(r.endTimes[1128] - r.startTimes[1115],
                       1.88 + (a.startTimes[1128] - a.startTimes[1115]), accuracy: 0.001)
    }
}
