import XCTest
@testable import ReaderCore

final class SpanLookupTests: XCTestCase {
    private func spans(_ surfaces: [String]) -> [TokenSpan] {
        surfaces.enumerated().map { i, s in
            TokenSpan(index: i, surface: s, reading: nil, dictionaryForm: s,
                      start: 0, end: 0, matchedChars: 0)
        }
    }

    private func info(rank: Int = 999, word: Bool = true,
                      exp: Bool = false, nonExp: Bool = true) -> SurfaceInfo {
        SurfaceInfo(priorityRank: rank, matchedWord: word, matchedReadingOnly: !word,
                    hasExpressionSense: exp, hasNonExpressionSense: nonExp)
    }

    private func isWord(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x3041...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
    }

    private func run(_ surfaces: [String], at i: Int, _ table: [String: SurfaceInfo]) -> [String] {
        spanLookupCandidates(spans: spans(surfaces), at: i, isWord: isWord) { table[$0] }
            .map(\.surface)
    }

    func testCompoundWinsFromAnyTapInsideIt() {
        let s = ["必ず", "法定", "代理", "人", "の", "同意"]
        let t = ["法定": info(rank: 11), "代理": info(rank: 3), "人": info(rank: 50),
                 "代理人": info(rank: 50), "法定代理人": info(rank: 999)]
        XCTAssertEqual(run(s, at: 1, t).first, "法定代理人")
        XCTAssertEqual(run(s, at: 2, t).first, "法定代理人")
        XCTAssertEqual(run(s, at: 3, t).first, "法定代理人")
    }

    func testRank999DoesNotRejectACompound() {
        let s = ["法定", "代理", "人"]
        XCTAssertEqual(run(s, at: 1, ["代理": info(rank: 3), "法定代理人": info(rank: 999)]).first,
                       "法定代理人")
    }

    func testExpressionOnlySpanDemotedBelowCommonSeed() {
        let s = ["研究", "生活", "を", "送る"]
        let t = ["生活": info(rank: 1), "生活を送る": info(rank: 999, exp: true, nonExp: false)]
        let r = run(s, at: 1, t)
        XCTAssertEqual(r.first, "生活")
        XCTAssertTrue(r.contains("生活を送る"))
    }

    func testDemotionFallsBackToSeedNotNextLongest() {
        let s = ["医者", "と", "し", "て", "まだ"]
        let t = ["と": info(rank: 1), "とし": info(rank: 1, word: false),
                 "として": info(rank: 999, exp: true, nonExp: false)]
        XCTAssertEqual(run(s, at: 1, t).first, "と")
    }

    func testSpuriousKanaReadingSpanDemoted() {
        let s = ["そこ", "に", "ある"]
        let t = ["そこ": info(rank: 1), "そこに": info(rank: 999, word: false)]
        XCTAssertEqual(run(s, at: 0, t).first, "そこ")
    }

    func testPunctuationBreaksTheChain() {
        let s = ["人", "（", "ご", "両親"]
        let t = ["人": info(rank: 50), "人（ご両親": info(rank: 1)]
        XCTAssertEqual(run(s, at: 0, t), ["人"])
    }

    func testSeedAlwaysPresentWithoutAnyEntry() {
        XCTAssertEqual(run(["触っ", "て"], at: 0, [:]), ["触っ"])
    }

    func testNonWordSeedYieldsNothing() {
        XCTAssertTrue(run(["、", "本"], at: 0, ["、": info()]).isEmpty)
    }
}
