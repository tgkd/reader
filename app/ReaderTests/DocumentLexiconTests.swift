import XCTest
import ReaderCore
@testable import Reader

final class DocumentLexiconTests: XCTestCase {

    private func reading(_ start: Int, _ surface: String, _ reading: String,
                         raw: String? = nil) -> SourceReading {
        SourceReading(start: start, length: surface.count, surface: surface,
                      reading: reading, rawReading: raw)
    }

    func testBuildsRulesFromAWholeDocument() async {
        let doc = Document(title: "本", chapters: [
            Chapter(text: "黄前久美子です。", sourceReadings: [reading(0, "黄前", "おうまえ")]),
            Chapter(text: "また黄前さん。", sourceReadings: [reading(2, "黄前", "おうまえ")]),
        ])

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker())
        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "黄前", reading: "おうまえ")])
    }

    func testAChapterLeavingTheSurfaceBareSinksTheRule() async {
        let doc = Document(title: "本", chapters: [
            Chapter(text: "希美さん。", sourceReadings: [reading(0, "希美", "のぞみ")]),
            Chapter(text: "希美子さんも来た。"),
        ])

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker())
        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertTrue(lex.rejected.contains { $0.surface == "希美" })
    }

    func testCorroboratesARepairedReadingAgainstTheRealTokenizer() async {
        let doc = Document(title: "本", chapters: [
            Chapter(text: "饒舌な人。",
                    sourceReadings: [reading(0, "饒舌", "じょうぜつ", raw: "じようぜつ")],
                    isFlattenedSource: true),
        ])

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker())
        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "饒舌", reading: "じょうぜつ")],
                       "MeCab knows 饒舌, so the repair is confirmed and its spelling wins")
    }

    func testARepairedNameTheTokenizerCannotConfirmIsDropped() async {
        let doc = Document(title: "本", chapters: [
            Chapter(text: "明静工科高校。",
                    sourceReadings: [reading(0, "明静工科", "みょうじょうこうか",
                                             raw: "みようじようこうか")],
                    isFlattenedSource: true),
        ])

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker())
        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first?.rejection, .unconfirmedRepair)
    }

    func testAnUntouchedReadingInAFlattenedBookNeedsNoTokenizer() async {
        let doc = Document(title: "本", chapters: [
            Chapter(text: "黄前久美子です。",
                    sourceReadings: [reading(0, "黄前", "おうまえ")],
                    isFlattenedSource: true),
        ])

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker())
        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "黄前", reading: "おうまえ")])
    }

    func testTokenizerReadingTilesAMultiTokenSurface() async {
        let worker = TokenizerWorker()
        let found = await worker.readings(of: ["饒舌", "存在しない架空語彙"])
        XCTAssertEqual(found["饒舌"], "じょうぜつ")
    }
}
