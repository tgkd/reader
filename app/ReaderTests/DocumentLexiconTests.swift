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

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker()).lexicon
        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "黄前", reading: "おうまえ")])
    }

    func testAChapterLeavingTheSurfaceBareSinksTheRule() async {
        let doc = Document(title: "本", chapters: [
            Chapter(text: "希美さん。", sourceReadings: [reading(0, "希美", "のぞみ")]),
            Chapter(text: "希美子さんも来た。"),
        ])

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker()).lexicon
        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertTrue(lex.rejected.contains { $0.surface == "希美" })
    }

    func testCorroboratesARepairedReadingAgainstTheRealTokenizer() async {
        let doc = Document(title: "本", chapters: [
            Chapter(text: "饒舌な人。",
                    sourceReadings: [reading(0, "饒舌", "じょうぜつ", raw: "じようぜつ")],
                    isFlattenedSource: true),
        ])

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker()).lexicon
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

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker()).lexicon
        XCTAssertTrue(lex.rules.isEmpty)
        XCTAssertEqual(lex.rejected.first?.rejection, .unconfirmedRepair)
    }

    func testAnUntouchedReadingInAFlattenedBookNeedsNoTokenizer() async {
        let doc = Document(title: "本", chapters: [
            Chapter(text: "黄前久美子です。",
                    sourceReadings: [reading(0, "黄前", "おうまえ")],
                    isFlattenedSource: true),
        ])

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker()).lexicon
        XCTAssertEqual(lex.rules, [PronunciationRule(surface: "黄前", reading: "おうまえ")])
    }

    func testTokenizerReadingTilesAMultiTokenSurface() async {
        let worker = TokenizerWorker()
        let found = await worker.readings(of: ["饒舌", "存在しない架空語彙"])
        XCTAssertEqual(found["饒舌"], "じょうぜつ")
    }

    private final class TokenizeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var texts: [String] = []
        func record(_ text: String) { lock.withLock { texts.append(text) } }
    }

    private func annotatedDocument() -> Document {
        Document(title: "本", chapters: [
            Chapter(text: "黄前久美子です。", sourceReadings: [reading(0, "黄前", "おうまえ")]),
            Chapter(text: "また黄前さん。", sourceReadings: [reading(2, "黄前", "おうまえ")]),
            Chapter(text: "ルビのない章。"),
        ])
    }

    func testEveryAnnotatedChapterIsTokenizedExactlyOnce() async {
        let doc = annotatedDocument()
        let counter = TokenizeCounter()

        let built = await DocumentLexicon.build(
            for: doc,
            readings: { _ in [:] },
            tokenize: { text in counter.record(text); return [Token(surface: text)] })

        XCTAssertEqual(counter.texts, [doc.chapters[0].text, doc.chapters[1].text],
                       "a chapter without ruby is not tokenized, and none is tokenized twice")
        XCTAssertEqual(Set(built.rawTokensByChapterID.keys),
                       Set([doc.chapters[0].id, doc.chapters[1].id]))
    }

    func testASeededTokenStreamIsNotTokenizedAgain() async {
        let doc = annotatedDocument()
        let counter = TokenizeCounter()
        let chapter = doc.chapters[0]
        let seed = [chapter.id: DocumentLexicon.ChapterTokens(
            normalizedText: Normalize.nfkc(chapter.text),
            tokens: [Token(surface: chapter.text)])]

        _ = await DocumentLexicon.build(
            for: doc, seeded: seed,
            readings: { _ in [:] },
            tokenize: { text in counter.record(text); return [Token(surface: text)] })

        XCTAssertEqual(counter.texts, [doc.chapters[1].text],
                       "the reader's own pass over the open chapter must be reused, not repeated")
    }

    func testASeedThatNoLongerDescribesTheChapterIsIgnored() async {
        let doc = annotatedDocument()
        let counter = TokenizeCounter()
        let chapter = doc.chapters[0]
        let seed = [chapter.id: DocumentLexicon.ChapterTokens(
            normalizedText: "まったく別の本文。",
            tokens: [Token(surface: "まったく別の本文。")])]

        _ = await DocumentLexicon.build(
            for: doc, seeded: seed,
            readings: { _ in [:] },
            tokenize: { text in counter.record(text); return [Token(surface: text)] })

        XCTAssertEqual(counter.texts, [doc.chapters[0].text, doc.chapters[1].text],
                       "retained tokens must not survive a change to the chapter's text")
    }
}
