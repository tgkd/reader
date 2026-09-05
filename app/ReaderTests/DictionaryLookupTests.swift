import XCTest
import ReaderCore
import SQLite3
@testable import Reader

final class DictionaryLookupTests: XCTestCase {
    func testHidoiThroughTokenizerAndLookup() async throws {
        let dictionary = try XCTUnwrap(SQLiteDictionaryService())
        let worker = TokenizerWorker()
        for text in ["ひどい", "ヒドイ", "ヒドい", "ひどかった", "酷い"] {
            let parsed = await worker.tokenize(text)
            let tokens = try XCTUnwrap(parsed)
            let spans = SpanTimeline(untimedTokens: tokens).spans
            let candidate = try XCTUnwrap(spanLookupCandidates(
                spans: spans, at: 0, isWord: Furigana.hasWordCharacter,
                info: dictionary.surfaceInfo).first)
            let token = try XCTUnwrap(tokens.first)
            let result = dictionary.lookup(
                dictionaryForm: candidate.isSeed ? token.dictionaryForm ?? token.surface : candidate.surface,
                reading: candidate.isSeed ? token.reading : nil)
            print("DICTCASE \(text): \(tokens) => \(result?.word ?? "MISS")")
            XCTAssertEqual(result?.word, "酷い", text)
        }
    }

    func testExactAlternateSpellings() throws {
        let dictionary = try XCTUnwrap(SQLiteDictionaryService())
        for (form, word) in [("呑む", "飲む"), ("衝く", "突く"), ("不ぞろい", "不揃い"),
                             ("恐い", "怖い"), ("ひでえ", "酷い")] {
            XCTAssertEqual(dictionary.lookup(dictionaryForm: form, reading: nil)?.word, word, form)
            XCTAssertNotNil(dictionary.surfaceInfo(form), form)
        }
    }

    func testDoesNotGuessFromSubstringOrAnUnrelatedReading() throws {
        let dictionary = try XCTUnwrap(SQLiteDictionaryService())
        XCTAssertNil(dictionary.lookup(dictionaryForm: "ヒド", reading: "ひど"))
        XCTAssertNil(dictionary.lookup(dictionaryForm: "架空の語彙XYZ", reading: "ひどい"))
    }

    func testAmbiguousAliasesNeedAUniqueReadingAndNeverOverrideExactWords() throws {
        try withFixture(aliases: true) { dictionary in
            XCTAssertNil(dictionary.lookup(dictionaryForm: "別表記", reading: nil))
            XCTAssertNil(dictionary.surfaceInfo("別表記"))
            XCTAssertEqual(dictionary.lookup(dictionaryForm: "別表記", reading: "カナ")?.word, "仮名")
            XCTAssertEqual(dictionary.lookup(dictionaryForm: "仮名", reading: nil)?.word, "仮名")
        }
    }

    func testLegacyDatabaseStillSupportsKanaFolding() throws {
        try withFixture(aliases: false) { dictionary in
            XCTAssertEqual(dictionary.lookup(dictionaryForm: "ｶﾅ", reading: nil)?.word, "仮名")
            XCTAssertNotNil(dictionary.surfaceInfo("カナ"))
            XCTAssertNil(dictionary.lookup(dictionaryForm: "別表記", reading: nil))
        }
    }

    private func withFixture(aliases: Bool, _ body: (SQLiteDictionaryService) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dict \(UUID()).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE words (id INTEGER PRIMARY KEY, word TEXT, reading TEXT, reading_hiragana TEXT, priority_rank INTEGER);
            CREATE TABLE meanings (id INTEGER PRIMARY KEY, word_id INTEGER, meaning TEXT, part_of_speech TEXT, misc TEXT, field TEXT);
            CREATE TABLE examples (word_id INTEGER, japanese_text TEXT, english_text TEXT, reading TEXT);
            INSERT INTO words VALUES (1, '仮名', 'かな', 'かな', 50), (2, '別名', 'べつめい', 'べつめい', 1);
            INSERT INTO meanings VALUES (1, 1, 'kana', 'n', NULL, NULL), (2, 2, 'alias', 'n', NULL, NULL);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        if aliases {
            XCTAssertEqual(sqlite3_exec(db, """
                CREATE TABLE word_aliases (word_id INTEGER, surface TEXT, surface_hiragana TEXT, form_kind TEXT);
                INSERT INTO word_aliases VALUES (1, '別表記', NULL, 'kanji'), (2, '別表記', NULL, 'kanji'), (2, '仮名', NULL, 'kanji');
                """, nil, nil, nil), SQLITE_OK)
        }
        sqlite3_close(db)
        try body(XCTUnwrap(SQLiteDictionaryService(path: url.path)))
    }

    func testLocalBookChapterCoverage() async throws {
        guard let path = PrivateSamples.firstEPUB() else {
            throw XCTSkip("No local test book")
        }
        let chapters = try await EPUBImporter(url: URL(fileURLWithPath: path)).chapters()
            .flatMap { $0.splitToRenderable() }
        let chapter = try XCTUnwrap(chapters.first { $0.text.contains("ヒドイ") }
                                   ?? chapters.first { $0.text.count > 1500 })
        let parsed = await TokenizerWorker().tokenize(chapter.text)
        let tokens = try XCTUnwrap(parsed)
        let dictionary = try XCTUnwrap(SQLiteDictionaryService())
        var seen = Set<String>()
        var misses: [String] = []
        var hits = 0
        for token in tokens where Furigana.hasWordCharacter(token.surface) {
            let query = token.dictionaryForm ?? token.surface
            guard seen.insert(query).inserted else { continue }
            if dictionary.lookup(dictionaryForm: query, reading: token.reading) == nil {
                misses.append("\(token.surface) → \(query) [\(token.reading ?? "-")]")
            } else {
                hits += 1
            }
        }
        print("DICTAUDIT chapter=\(chapter.title ?? "untitled") chars=\(chapter.text.count) unique=\(seen.count) hits=\(hits) misses=\(misses.count)")
        print("DICTMISSES \(misses.joined(separator: " | "))")
        XCTAssertGreaterThan(hits, 0)
    }
}
