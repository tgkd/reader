import XCTest
import ReaderCore
@testable import Reader

final class StarterBooksFuriganaTests: XCTestCase {
    private func rendered(_ id: String) async throws -> [String: String] {
        let book = try XCTUnwrap(StarterLibrary.books.first { $0.id == id })
        let document = try await Importer.document(from: XCTUnwrap(StarterLibrary.url(for: book)))
        let tok = try MeCabTokenizer()
        var out: [String: String] = [:]
        for chapter in document.chapters {
            for token in SourceReadingOverlay.apply(chapter.sourceReadings,
                                                    to: tok.tokenize(chapter.text),
                                                    text: chapter.text) {
                if out[token.surface] == nil, let reading = token.reading {
                    out[token.surface] = reading
                }
            }
        }
        return out
    }

    func testNamesAndGikunRenderAsTheBookPrintsThem() async throws {
        let expected: [String: [String: String]] = [
            "gon-gitsune": ["兵十": "ひょうじゅう", "二人": "ふたり", "一人": "ひとり",
                            "弥助": "やすけ", "午飯": "ひるめし"],
            "kumo-no-ito": ["御釈迦様": "おしゃかさま", "犍陀多": "かんだた", "三途": "さんず"],
            "yume-juya": ["洋杖": "ステッキ", "御百度": "おひゃくど", "水蜜桃": "すいみつとう"],
            "lemon": ["翡翠色": "ひすいいろ", "快速調": "アッレグロ"],
            "rashomon": ["市女笠": "いちめがさ", "築土": "ついじ"],
        ]
        for (id, words) in expected {
            let readings = try await rendered(id)
            for (surface, reading) in words {
                XCTAssertEqual(readings[surface], reading,
                               "\(id): the book prints \(surface) as \(reading); no tokenizer "
                                   + "can derive it, so the annotation must reach the page")
            }
        }
    }

    func testAlmostEveryAnnotationReachesThePage() async throws {
        let tok = try MeCabTokenizer()
        var total = 0, applied = 0
        for book in StarterLibrary.books {
            let document = try await Importer.document(from: XCTUnwrap(StarterLibrary.url(for: book)))
            for chapter in document.chapters {
                let readings = chapter.sourceReadings.validated(against: chapter.text)
                guard !readings.isEmpty else { continue }
                let tokens = SourceReadingOverlay.joiningAcrossAnnotations(
                    readings, tokens: tok.tokenize(chapter.text), text: chapter.text)
                let book = SourceReadingOverlay.bookReadings(readings, tokens: tokens,
                                                             text: chapter.text)
                var starts: [Int] = []
                var cursor = 0
                for token in tokens {
                    starts.append(cursor)
                    cursor += token.surface.count
                }
                let raw = Array(chapter.text)
                for reading in readings {
                    total += 1
                    let start = Normalize.nfkc(String(raw[0..<reading.start])).count
                    guard let host = starts.lastIndex(where: { $0 <= start }),
                          book[host] != nil else { continue }
                    applied += 1
                }
            }
        }
        XCTAssertGreaterThan(total, 1800, "the eight starter books should carry ~1881 annotations")
        let rate = Double(applied) / Double(total)
        XCTAssertGreaterThan(rate, 0.98,
                             """
                             \(applied)/\(total) annotations reached the page. Joining token runs \
                             took this from 84% to 99%; the remainder are annotations covering \
                             part of a token whose rest is not kana (掻 inside 掻き立て), which are \
                             refused on purpose
                             """)
    }

    func testJoiningNeverBreaksTheTokenStream() async throws {
        let tok = try MeCabTokenizer()
        for book in StarterLibrary.books {
            let document = try await Importer.document(from: XCTUnwrap(StarterLibrary.url(for: book)))
            for chapter in document.chapters {
                let tokens = SourceReadingOverlay.apply(chapter.sourceReadings,
                                                        to: tok.tokenize(chapter.text),
                                                        text: chapter.text)
                let nfkc = Normalize.nfkc(chapter.text)
                XCTAssertEqual(tokens.map(\.surface).joined(), nfkc,
                               "\(book.id): surfaces must still concatenate to the NFKC text")
                XCTAssertEqual(tokens.reduce(0) { $0 + $1.surface.count }, nfkc.count,
                               "\(book.id): the character count is what saved offsets walk on")
            }
        }
    }
}
