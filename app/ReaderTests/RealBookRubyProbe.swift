import XCTest
import ReaderCore
@testable import Reader

/// One-off probe against a real book on disk (path via `YOMI_EPUB`). Skips when the
/// variable is unset, so it never runs in CI — it exists to confirm the ruby path
/// end to end on actual publisher markup rather than on a synthetic fixture.
final class RealBookRubyProbe: XCTestCase {

    func testRealBookReadings() async throws {
        guard let path = ProcessInfo.processInfo.environment["YOMI_EPUB"] else {
            throw XCTSkip("set YOMI_EPUB to a book path")
        }
        let chapters = try await EPUBImporter(url: URL(fileURLWithPath: path)).chapters()
            .flatMap { $0.splitToRenderable() }

        let annotated = chapters.filter { !$0.sourceReadings.isEmpty }
        print("PROBE chapters \(chapters.count), annotated \(annotated.count), "
              + "readings \(annotated.reduce(0) { $0 + $1.sourceReadings.count })")

        let tok = try MeCabTokenizer()
        var shown = 0
        for chapter in annotated {
            let before = tok.tokenize(chapter.text)
            let after = SourceReadingOverlay.apply(chapter.sourceReadings,
                                                   to: before, text: chapter.text)
            for (b, a) in zip(before, after) where b.reading != a.reading {
                print("PROBE  \(a.surface)  mecab=\(b.reading ?? "-")  book=\(a.reading ?? "-")")
                shown += 1
                if shown >= 40 { return }
            }
        }
        XCTAssertGreaterThan(shown, 0, "no reading was overridden anywhere in the book")
    }
}
