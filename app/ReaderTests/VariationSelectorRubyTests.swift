import XCTest
import ReaderCore
@testable import Reader

final class VariationSelectorRubyTests: XCTestCase {
    private let vs = "\u{E0100}"

    private func chapters(_ url: URL) async throws -> [Chapter] {
        try await EPUBImporter(url: url).chapters()
    }

    private func book(_ body: String) throws -> URL {
        try Fixture.epub(manifest: [Fixture.EPUBItem(id: "ch1", href: "ch1.xhtml",
                                                     content: Fixture.xhtml(body: body))],
                         spine: [Fixture.SpineRef("ch1")])
    }

    func testRubyReachesTheSameNameWrittenWithoutItsSelector() async throws {
        let url = try book("""
        <p><ruby>葛\(vs)城<rt>かつらぎ</rt></ruby>さんが来た。</p>
        <p>葛\(vs)城さんは笑った。</p>
        <p>葛城さんは帰った。</p>
        """)
        let chapter = try await chapters(url)[0]

        let katsuragi = chapter.sourceReadings.filter { $0.reading == "かつらぎ" }
        XCTAssertEqual(katsuragi.count, 3,
                       """
                       the book states this name once; propagation must reach both the identical \
                       spelling and the one written without the variation selector, which is the \
                       same word — got \(chapter.sourceReadings.map { ($0.surface, $0.reading) })
                       """)

        let surfaces = Set(katsuragi.map(\.surface))
        XCTAssertEqual(surfaces, ["葛\(vs)城", "葛城"],
                       "each reading must carry the surface as it appears at its own site")

        for reading in katsuragi {
            let chars = Array(chapter.text)
            XCTAssertEqual(String(chars[reading.start..<reading.end]), reading.surface,
                           "a propagated reading must still validate against the text")
        }
    }

    func testBothSpellingsBecomePronunciationRules() async throws {
        let url = try book("""
        <p><ruby>葛\(vs)城<rt>かつらぎ</rt></ruby>さんが来た。</p>
        <p>葛城さんは帰った。</p>
        """)
        let chapter = try await chapters(url)[0]
        let tokens = try MeCabTokenizer().tokenize(chapter.text)
        let lexicon = PronunciationLexicon.build(text: chapter.text,
                                                 readings: chapter.sourceReadings,
                                                 tokens: tokens)

        let bySurface = Dictionary(uniqueKeysWithValues: lexicon.rules.map { ($0.surface, $0.reading) })
        XCTAssertEqual(bySurface["葛\(vs)城"], "かつらぎ")
        XCTAssertEqual(bySurface["葛城"], "かつらぎ",
                       """
                       ElevenLabs matches dictionary entries by exact string, so a rule keyed only \
                       on the selector-bearing spelling leaves the bare one to be guessed — which \
                       is how one 葛城 in three came out mispronounced on device
                       """)
    }

    func testASelectorlessBookIsUnaffected() async throws {
        let url = try book("""
        <p><ruby>葛城<rt>かつらぎ</rt></ruby>さんが来た。</p>
        <p>葛城さんは帰った。</p>
        """)
        let chapter = try await chapters(url)[0]
        let readings = chapter.sourceReadings.filter { $0.reading == "かつらぎ" }
        XCTAssertEqual(readings.count, 2)
        XCTAssertEqual(Set(readings.map(\.surface)), ["葛城"])
    }
}
