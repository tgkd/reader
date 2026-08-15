import XCTest
import ReaderCore
@testable import Reader

final class StarterBooksTests: XCTestCase {
    func testEveryListedBookIsBundled() {
        for book in StarterLibrary.books {
            XCTAssertNotNil(StarterLibrary.url(for: book),
                            "\(book.id).epub is listed in StarterLibrary but not bundled")
        }
    }

    func testBundledMetadataMatchesTheListedTitleAndAuthor() async throws {
        for book in StarterLibrary.books {
            let url = try XCTUnwrap(StarterLibrary.url(for: book))
            let document = try await Importer.document(from: url)
            XCTAssertEqual(document.title, book.title, "\(book.id) OPF title drifted from StarterLibrary")
            XCTAssertEqual(document.author, book.author, "\(book.id) OPF creator drifted from StarterLibrary")
        }
    }

    func testChaptersStayWithinTheRenderableCap() async throws {
        for book in StarterLibrary.books {
            let url = try XCTUnwrap(StarterLibrary.url(for: book))
            let document = try await Importer.document(from: url)
            XCTAssertFalse(document.chapters.isEmpty, "\(book.id) imported no chapters")
            for chapter in document.chapters {
                XCTAssertLessThanOrEqual(chapter.text.count, Chapter.maxRenderableChars,
                                         "\(book.id) has a chapter over the renderable cap")
                XCTAssertFalse(chapter.text.isEmpty, "\(book.id) has an empty chapter")
            }
        }
    }

    func testNoUnresolvedGaijiSurvivesTheConversion() async throws {
        for book in StarterLibrary.books {
            let url = try XCTUnwrap(StarterLibrary.url(for: book))
            let text = try await Importer.document(from: url).chapters.map(\.text).joined()
            XCTAssertFalse(text.contains("※（"), "\(book.id) still carries an Aozora gaiji note")
            XCTAssertFalse(text.contains("※("), "\(book.id) still carries an Aozora gaiji note")
            XCTAssertFalse(text.contains("水準"), "\(book.id) still carries a JIS kuten reference")
            XCTAssertFalse(text.contains("<"), "\(book.id) still carries markup")
        }
    }

    func testPublisherRubyReachesEveryBookAndAlignsWithItsText() async throws {
        for book in StarterLibrary.books {
            let url = try XCTUnwrap(StarterLibrary.url(for: book))
            let document = try await Importer.document(from: url)
            let readings = document.chapters.flatMap(\.sourceReadings)
            XCTAssertFalse(readings.isEmpty,
                           "\(book.id) carries no publisher ruby — the reason these are EPUB")

            for chapter in document.chapters {
                let chars = Array(chapter.text)
                for reading in chapter.sourceReadings {
                    XCTAssertLessThanOrEqual(reading.end, chars.count,
                                             "\(book.id): reading runs past the chapter text")
                    guard reading.end <= chars.count else { continue }
                    XCTAssertEqual(String(chars[reading.start..<reading.end]), reading.surface,
                                   "\(book.id): ruby offset does not land on its own surface")
                }
            }
        }
    }

    func testResolvedGaijiSurvivesAsRealCharacters() async throws {
        let url = try XCTUnwrap(StarterLibrary.url(for: XCTUnwrap(
            StarterLibrary.books.first { $0.id == "sangetsuki" })))
        let text = try await Importer.document(from: url).chapters.map(\.text).joined()
        XCTAssertTrue(text.contains("袁傪"),
                      "the JIS X 0213 gaiji 傪 must survive as a character, not an image")
    }

    func testAstralPlaneGaijiSurvivesAsASingleCharacter() async throws {
        let url = try XCTUnwrap(StarterLibrary.url(for: XCTUnwrap(
            StarterLibrary.books.first { $0.id == "lemon" })))
        let text = try await Importer.document(from: url).chapters.map(\.text).joined()
        XCTAssertTrue(text.unicodeScalars.contains { $0.value == 0x24103 },
                      "U+24103 is outside the BMP and must survive as one Character")
    }
}
