import XCTest
@testable import ReaderCore

/// Phase 3 of the sync spike: proves the char→token mapper on REAL ElevenLabs
/// alignment data. Auto-skips until a fixture exists. Capture one with:
///   ELEVENLABS_KEY=sk_... node scripts/capture-alignment.mjs "…" sample
final class AlignmentFixtureTests: XCTestCase {

    private struct Fixture: Decodable {
        let text: String
        let alignment: Alignment
    }

    private func fixturesDir() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("fixtures")
    }

    func testRealAlignmentFixtures() throws {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: fixturesDir(), includingPropertiesForKeys: nil)) ?? []
        let jsons = urls.filter { $0.pathExtension == "json" }
        try XCTSkipIf(jsons.isEmpty,
                      "No captured ElevenLabs fixtures yet — run scripts/capture-alignment.mjs with your key.")

        let tok = try MeCabTokenizer()
        for url in jsons.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = url.lastPathComponent
            let fx = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            let tokens = tok.tokenize(fx.text)
            XCTAssertFalse(tokens.isEmpty, "\(name): tokenizer produced nothing")

            let spans = CharTokenMapper.map(tokens: tokens, alignment: fx.alignment)
            XCTAssertEqual(spans.count, tokens.count, "\(name): span/token count mismatch")

            for k in spans.indices {
                XCTAssertFalse(spans[k].start.isNaN || spans[k].end.isNaN, "\(name): NaN span at \(k)")
                XCTAssertGreaterThanOrEqual(spans[k].end, spans[k].start, "\(name): end<start at \(k)")
                if k > 0 {
                    XCTAssertGreaterThanOrEqual(spans[k].start, spans[k - 1].start,
                                                "\(name): non-monotonic start at \(k)")
                }
            }

            let covered = Double(spans.filter { $0.matchedChars > 0 }.count) / Double(spans.count)
            XCTAssertGreaterThan(covered, 0.9,
                                 "\(name): only \(Int(covered * 100))% of tokens matched an alignment char")

            print("=== \(name): \(spans.count) tokens, char-match coverage \(Int(covered * 100))% ===")
            for s in spans.prefix(60) {
                let r = s.reading.map { " (\($0))" } ?? ""
                print(String(format: "  %6.2f–%6.2f  %@%@", s.start, s.end, s.surface, r))
            }
        }
    }
}
