import XCTest
@testable import ReaderCore

final class FeatureFieldTests: XCTestCase {
    func testEmptyColumnsAreKeptSoFieldIndicesDoNotShift() {
        "名詞,,固有名詞,*".withCString { blob in
            XCTAssertEqual(MeCabTokenizer.field(blob, at: 0), "名詞")
            XCTAssertEqual(MeCabTokenizer.field(blob, at: 1), "",
                           """
                           an empty column must occupy its index: Mecab-Swift split with \
                           omittingEmptySubsequences defaulting to true, which would shift \
                           原形 and 読み one place left
                           """)
            XCTAssertEqual(MeCabTokenizer.field(blob, at: 2), "固有名詞")
            XCTAssertEqual(MeCabTokenizer.field(blob, at: 3), "*")
            XCTAssertNil(MeCabTokenizer.field(blob, at: 4),
                         "past the last column the field is absent, not empty")
        }
    }

    func testTrailingEmptyColumnIsAFieldAndNotAnAbsence() {
        "a,b,".withCString { blob in
            XCTAssertEqual(MeCabTokenizer.field(blob, at: 2), "")
            XCTAssertNil(MeCabTokenizer.field(blob, at: 3))
        }
    }

    func testUnknownWordFallsBackToItsOwnSurfaceForTheReading() throws {
        let tokens = try MeCabTokenizer().tokenize("ロギンした")
        let unknown = try XCTUnwrap(tokens.first { $0.surface.contains("ロギン") },
                                    "expected a ロギン token; got \(tokens.map(\.surface))")
        XCTAssertEqual(unknown.reading, "ろぎん",
                       """
                       unk.dic rows carry 7 fields, so index 7 (読み) is absent and the reading \
                       falls back to the surface — the fallback TokenizerWorker.reading(of:) \
                       depends on, since it requires readings.count == tokens.count
                       """)
    }

    func testKnownWordTakesItsReadingAndLemmaFromTheDictionary() throws {
        let tokens = try MeCabTokenizer().tokenize("走った")
        let verb = try XCTUnwrap(tokens.first { $0.surface == "走っ" })
        XCTAssertEqual(verb.reading, "はしっ")
        XCTAssertEqual(verb.dictionaryForm, "走る")
    }
}
