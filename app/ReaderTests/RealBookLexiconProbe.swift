import XCTest
import ReaderCore
@testable import Reader

final class RealBookLexiconProbe: XCTestCase {
    func testRealBookLexicon() async throws {
        guard let path = ProcessInfo.processInfo.environment["YOMI_EPUB"] else {
            throw XCTSkip("set YOMI_EPUB to a book path")
        }
        let chapters = try await EPUBImporter(url: URL(fileURLWithPath: path)).chapters()
            .flatMap { $0.splitToRenderable() }
        let doc = Document(title: "probe", chapters: chapters)

        let readings = chapters.reduce(0) { $0 + $1.sourceReadings.count }
        let flattened = chapters.contains { $0.isFlattenedSource }
        let repaired = chapters.flatMap(\.sourceReadings).filter(\.wasRepaired).count
        print("LEX book \(URL(fileURLWithPath: path).lastPathComponent)")
        print("LEX chapters \(chapters.count), readings \(readings), "
              + "flattened \(flattened), repaired \(repaired)")

        let lex = await DocumentLexicon.build(for: doc, using: TokenizerWorker())

        let occurrences = { (surface: String) -> Int in
            chapters.reduce(0) { total, c in
                total + c.text.ranges(of: surface).count
            }
        }
        let covered = lex.rules.reduce(0) { $0 + occurrences($1.surface) }
        print("LEX rules \(lex.rules.count), covering \(covered) occurrences")

        var byReason: [String: Int] = [:]
        for c in lex.rejected {
            let key: String
            switch c.rejection {
            case .singleCharacterBase: key = "singleCharacterBase"
            case .ambiguousInBook: key = "ambiguousInBook"
            case .readingNotKana: key = "readingNotKana"
            case .readingMatchesSurface: key = "readingMatchesSurface"
            case .unannotatedOccurrence: key = "unannotatedOccurrence"
            case .insideLongerReading: key = "insideLongerReading"
            case .unconfirmedRepair: key = "unconfirmedRepair"
            case .none: key = "none"
            }
            byReason[key, default: 0] += 1
        }
        print("LEX rejected \(lex.rejected.count)")
        for (k, v) in byReason.sorted(by: { $0.value > $1.value }) {
            print("LEX   \(v)\t\(k)")
        }

        print("LEX ---- admitted, most frequent first ----")
        for r in lex.rules.sorted(by: { occurrences($0.surface) > occurrences($1.surface) }).prefix(30) {
            print("LEX   \(r.surface)\t→ \(r.reading)\t×\(occurrences(r.surface))")
        }

        let payload = lex.rules.map { ["string_to_replace": $0.surface, "alias": $0.reading] }
        if let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            print("LEXJSON \(json)")
        }

        let scored = chapters.enumerated().map { i, c in
            (i, lex.rules.reduce(0) { $0 + c.text.ranges(of: $1.surface).count })
        }
        let pick = Int(ProcessInfo.processInfo.environment["YOMI_CHAPTER"] ?? "")
            ?? scored.max(by: { $0.1 < $1.1 })?.0 ?? 0
        if chapters.indices.contains(pick) {
            let text = chapters[pick].text
            let hits = lex.rules.filter { text.contains($0.surface) }
            print("LEXCHAPTER index \(pick), \(text.count) chars, "
                  + "\(hits.count)/\(lex.rules.count) rules applicable")
            print("LEXTEXT \(Data(text.utf8).base64EncodedString())")
            let subset = hits.map { ["string_to_replace": $0.surface, "alias": $0.reading] }
            if let data = try? JSONSerialization.data(withJSONObject: subset),
               let json = String(data: data, encoding: .utf8) {
                print("LEXSUBSET \(json)")
            }
        }

        print("LEX ---- refused, most frequent first ----")
        for c in lex.rejected.sorted(by: { $0.occurrences > $1.occurrences }).prefix(25) {
            print("LEX   \(c.surface)\t→ \(c.reading)\t×\(c.occurrences)\t\(c.rejection.map(String.init(describing:)) ?? "-")")
        }
    }
}
