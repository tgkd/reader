import XCTest
import ReaderCore
@testable import Reader

final class BookNarrationPipelineTests: XCTestCase {
    private let vs = "\u{E0100}"

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeService() -> WorkerTTSService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return WorkerTTSService(baseURL: URL(string: "https://test.example.com")!,
                                userId: { "user-123" },
                                session: URLSession(configuration: config))
    }

    private func book() throws -> URL {
        let body = """
        <p><ruby>黄前<rt>おうまえ</rt></ruby>さんは<ruby>葛\(vs)城<rt>かつらぎ</rt></ruby>で\
        ﾊﾞｽを待った。</p>
        <p><ruby>秀<rt>しゅう</rt>一<rt>いち</rt></ruby>が<ruby>響<rt>ひび</rt></ruby>けと言った。</p>
        <p>葛城は静かだった。</p>
        """
        return try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "ch1", href: "ch1.xhtml",
                                        content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("ch1")])
    }

    private func host(_ surface: String, in tokens: [Token]) throws -> Token {
        try XCTUnwrap(tokens.first { $0.surface.contains(surface) },
                      "no token hosts \(surface) — got \(tokens.map(\.surface))")
    }

    func testTheBookReachesTheWorkerAsThePageRendersIt() async throws {
        let document = try await Importer.document(from: book())
        let chapter = try XCTUnwrap(document.chapters.first)
        let raw = try MeCabTokenizer().tokenize(chapter.text)
        let tokens = SourceReadingOverlay.apply(chapter.sourceReadings, to: raw, text: chapter.text)
        let canonical = Normalize.nfkc(chapter.text)

        XCTAssertEqual(tokens.map(\.surface).joined(), canonical,
                       "surfaces must concatenate to the NFKC chapter text")
        XCTAssertEqual(tokens.reduce(0) { $0 + $1.surface.count }, canonical.count,
                       "the character count is what saved offsets and the lexicon walk need")

        let lexicon = await DocumentLexicon.build(for: document,
                                                  using: TokenizerWorker()).lexicon
        let request = SynthesisRequest(text: chapter.text, voice: .shizuka,
                                       pronunciation: lexicon.rules)
        _ = try? await makeService().synthesize(request)

        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sent = try XCTUnwrap(json["text"] as? String)

        XCTAssertEqual(Array(sent.utf8), Array(tokens.map(\.surface).joined().utf8),
                       "compare bytes: String == is canonical equivalence, and ﾊﾞｽ is exactly the "
                           + "case where normalizing twice is equal as Strings but not as bytes")
        XCTAssertEqual(Array(sent.utf8), Array(canonical.utf8))

        let rules = try XCTUnwrap(json["pronunciation_rules"] as? [[String: String]])
        XCTAssertEqual(rules, lexicon.rules.map { ["surface": $0.surface, "reading": $0.reading] },
                       "the wire must carry the book's lexicon exactly, in its own order")

        let bySurface = Dictionary(uniqueKeysWithValues: lexicon.rules.map { ($0.surface, $0.reading) })
        XCTAssertEqual(bySurface["黄前"], "おうまえ")
        XCTAssertEqual(bySurface["秀一"], "しゅういち", "grouped ruby must regroup into one rule")
        XCTAssertEqual(bySurface["葛\(vs)城"], "かつらぎ")
        XCTAssertEqual(bySurface["葛城"], "かつらぎ",
                       "ElevenLabs matches by exact string, so the selectorless spelling needs "
                           + "its own rule")
    }

    func testThePagePrefersThePublishersReadingOverTheTokenizers() async throws {
        let document = try await Importer.document(from: book())
        let chapter = try XCTUnwrap(document.chapters.first)
        let raw = try MeCabTokenizer().tokenize(chapter.text)
        let tokens = SourceReadingOverlay.apply(chapter.sourceReadings, to: raw, text: chapter.text)

        for (surface, reading) in [("黄前", "おうまえ"), ("葛\(vs)城", "かつらぎ"),
                                   ("秀", "しゅう"), ("響", "ひび")] {
            let token = try host(surface, in: tokens)
            let page = try XCTUnwrap(token.reading, "\(token.surface) reached the page unread")
            XCTAssertTrue(page.contains(reading),
                          "the book prints \(surface) as \(reading); \(token.surface) reads \(page)")
        }
    }
}
