import XCTest
import ReaderCore
@testable import Reader

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
        var repaired: [(Int, String, String, String, String)] = []
        var names: [String: Int] = [:]
        var seenRepair = Set<String>()

        for (i, chapter) in chapters.enumerated() where !chapter.sourceReadings.isEmpty {
            let before = tok.tokenize(chapter.text)
            let after = SourceReadingOverlay.apply(chapter.sourceReadings,
                                                   to: before, text: chapter.text)
            let title = chapter.title ?? "—"
            for (b, a) in zip(before, after) where b.reading != a.reading {
                guard let book = a.reading else { continue }
                let key = "\(a.surface)→\(book)"
                if KanaRepair.containsSmallKana(book),
                   !KanaRepair.containsSmallKana(b.reading ?? ""),
                   seenRepair.insert(key).inserted {
                    repaired.append((i + 1, title, a.surface, b.reading ?? "-", book))
                }
                if names[key] == nil { names[key] = i + 1 }
            }
        }

        print("PROBE ---- small-kana repairs, by chapter ----")
        for r in repaired.sorted(by: { $0.0 < $1.0 }) {
            print("PROBE  ch\(r.0) \(r.1)  \(r.2)  \(r.3) → \(r.4)")
        }
        print("PROBE ---- distinct overrides: \(names.count) ----")

        let watch = ["饒舌", "苗字", "躊躇", "几帳面", "刺繍", "華奢", "咀嚼",
                     "逡巡", "法隆寺", "平等院", "聖女", "秀一"]
        print("PROBE ---- watchlist: reading as rendered ----")
        var found = Set<String>()
        for (i, chapter) in chapters.enumerated() {
            guard watch.contains(where: { chapter.text.contains($0) }) else { continue }
            let after = SourceReadingOverlay.apply(chapter.sourceReadings,
                                                   to: tok.tokenize(chapter.text),
                                                   text: chapter.text)
            for t in after where watch.contains(t.surface) && !found.contains(t.surface) {
                found.insert(t.surface)
                let ok = KanaRepair.containsSmallKana(t.reading ?? "") ? "ok " : "CHECK"
                print("PROBE  \(ok) ch\(i + 1) \(chapter.title ?? "—")  \(t.surface) → \(t.reading ?? "-")")
            }
        }
        for w in watch where !found.contains(w) {
            print("PROBE  (not a single token anywhere: \(w))")
        }

        XCTAssertFalse(annotated.isEmpty, "no reading was overridden anywhere in the book")
    }
}
