import XCTest
@testable import ReaderCore

enum CorpusGolden {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(c)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var pending = false
        for c in s {
            if pending {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(c)
                }
                pending = false
            } else if c == "\\" {
                pending = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    static func line(_ token: Token) -> String {
        escape(token.surface) + "\t" + escape(token.reading ?? "") + "\t"
            + escape(token.dictionaryForm ?? "")
    }
}

final class CorpusInvariantTests: XCTestCase {
    private var corpusDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("corpus")
    }

    private func corpus() throws -> String {
        try String(contentsOf: corpusDir.appendingPathComponent("kokoro.txt"), encoding: .utf8)
    }

    func testSurfacesRejoinTheNormalizedCorpus() throws {
        let text = try corpus()
        let tokens = try MeCabTokenizer().tokenize(text)
        XCTAssertEqual(tokens.map(\.surface).joined(), Normalize.nfkc(text),
                       "concatenated surfaces must equal the NFKC corpus")
    }

    func testSurfaceCountsAreAdditive() throws {
        let text = try corpus()
        let normalized = Normalize.nfkc(text)
        let tokens = try MeCabTokenizer().tokenize(text)
        let sum = tokens.reduce(0) { $0 + $1.surface.count }
        XCTAssertEqual(sum, normalized.count,
                       """
                       every surface must be a Character-aligned slice of the normalized text: \
                       TokenOffsets, SourceReadingOverlay and PronunciationLexicon all walk tokens \
                       by a running sum of surface.count, and one split grapheme drifts every \
                       later token in the chapter
                       """)
    }

    func testTokenStreamMatchesTheCommittedGolden() throws {
        let text = try corpus()
        let tokens = try MeCabTokenizer().tokenize(text)
        let produced = tokens.map(CorpusGolden.line)
        let goldenURL = corpusDir.appendingPathComponent("kokoro-tokens.tsv")

        if ProcessInfo.processInfo.environment["YOMI_REGEN_GOLDEN"] != nil {
            try (produced.joined(separator: "\n") + "\n")
                .write(to: goldenURL, atomically: true, encoding: .utf8)
            throw XCTSkip("regenerated \(goldenURL.lastPathComponent) — review the diff and re-run")
        }

        let golden = try String(contentsOf: goldenURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropLast()
            .map(String.init)

        if let i = zip(produced, golden).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            XCTFail("""
                    token \(i) diverges from the golden stream
                      golden:   \(golden[i])
                      produced: \(produced[i])
                    Set YOMI_REGEN_GOLDEN=1 to rewrite it once the change is deliberate.
                    """)
        }
        XCTAssertEqual(produced.count, golden.count,
                       "token count changed; streams agree up to \(min(produced.count, golden.count))")
    }
}
