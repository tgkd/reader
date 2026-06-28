import XCTest
import ReaderCore
@testable import Reader

/// Exercises the real `EPUBImporter` over generated EPUBs: spine ordering,
/// `linear="no"` skipping, `<head>` isolation, entity decoding, and error cases.
final class EPUBImporterTests: XCTestCase {
    private func chapters(_ url: URL) throws -> [Chapter] {
        try EPUBImporter(url: url).chapters()
    }

    func testSpineDeterminesReadingOrderNotManifestOrder() throws {
        // Manifest declares b, a, c; spine asks for a, b, c — chapters must follow spine.
        let manifest = [
            Fixture.EPUBItem(id: "b", href: "b.xhtml", content: Fixture.xhtml(body: "<p>BRAVO</p>")),
            Fixture.EPUBItem(id: "a", href: "a.xhtml", content: Fixture.xhtml(body: "<p>ALPHA</p>")),
            Fixture.EPUBItem(id: "c", href: "c.xhtml", content: Fixture.xhtml(body: "<p>CHARLIE</p>")),
        ]
        let url = try Fixture.epub(manifest: manifest,
                                   spine: [Fixture.SpineRef("a"), Fixture.SpineRef("b"), Fixture.SpineRef("c")])
        let result = try chapters(url)
        XCTAssertEqual(result.map(\.text), ["ALPHA", "BRAVO", "CHARLIE"])
    }

    func testLinearNoItemsAreSkipped() throws {
        // Cover/footnotes marked linear="no" are auxiliary — not narrated chapters.
        let manifest = [
            Fixture.EPUBItem(id: "cover", href: "cover.xhtml", content: Fixture.xhtml(body: "<p>COVER</p>")),
            Fixture.EPUBItem(id: "ch1", href: "ch1.xhtml", content: Fixture.xhtml(body: "<p>BODY1</p>")),
            Fixture.EPUBItem(id: "ch2", href: "ch2.xhtml", content: Fixture.xhtml(body: "<p>BODY2</p>")),
        ]
        let url = try Fixture.epub(manifest: manifest, spine: [
            Fixture.SpineRef("cover", linear: false),
            Fixture.SpineRef("ch1"),
            Fixture.SpineRef("ch2"),
        ])
        let result = try chapters(url)
        XCTAssertEqual(result.map(\.text), ["BODY1", "BODY2"])
    }

    func testHeadMetadataDoesNotLeakIntoChapter() throws {
        // <head><title> must never appear in the extracted body text.
        let url = try Fixture.simpleEPUB(["本文だけ"])
        let result = try chapters(url)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "本文だけ")
        XCTAssertFalse(result[0].text.contains("HEAD_TITLE_DO_NOT_LEAK"))
    }

    func testHtmlEntitiesAreDecoded() throws {
        let body = "<p>A&amp;B &lt;tag&gt; &#38; &#x3042; x&nbsp;y</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let text = try chapters(url)[0].text
        XCTAssertTrue(text.contains("A&B"), text)
        XCTAssertTrue(text.contains("<tag>"), text)
        XCTAssertTrue(text.contains("あ"), text)      // &#x3042;
        XCTAssertTrue(text.contains("x y"), text)     // &nbsp; → space
        XCTAssertFalse(text.contains("&amp;"), text)  // no double-encoding left behind
    }

    func testBlockTagsBecomeLineBreaks() throws {
        let body = "<p>一行目</p><p>二行目</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let text = try chapters(url)[0].text
        XCTAssertEqual(text, "一行目\n二行目")
    }

    func testEmptyBodyItemsAreSkipped() throws {
        let manifest = [
            Fixture.EPUBItem(id: "a", href: "a.xhtml", content: Fixture.xhtml(body: "<p>REAL</p>")),
            Fixture.EPUBItem(id: "blank", href: "blank.xhtml", content: Fixture.xhtml(body: "")),
        ]
        let url = try Fixture.epub(manifest: manifest,
                                   spine: [Fixture.SpineRef("a"), Fixture.SpineRef("blank")])
        XCTAssertEqual(try chapters(url).map(\.text), ["REAL"])
    }

    func testNestedAndPercentEncodedHrefResolves() throws {
        // href in a subdir with a percent-encoded space — the importer decodes it.
        let manifest = [Fixture.EPUBItem(id: "c0", href: "text/ch%201.xhtml",
                                         content: Fixture.xhtml(body: "<p>NESTED</p>"))]
        let url = try Fixture.epub(manifest: manifest, spine: [Fixture.SpineRef("c0")])
        XCTAssertEqual(try chapters(url).map(\.text), ["NESTED"])
    }

    func testCorruptArchiveThrowsUnreadable() {
        let url = Fixture.write(Data("not a zip".utf8), ext: "epub")
        XCTAssertThrowsError(try chapters(url)) {
            XCTAssertEqual($0 as? ImportError, .unreadable)
        }
    }

    func testEmptySpineThrowsEmpty() throws {
        let manifest = [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: "<p>X</p>"))]
        let url = try Fixture.epub(manifest: manifest, spine: [])   // declared but no itemrefs
        XCTAssertThrowsError(try chapters(url)) {
            XCTAssertEqual($0 as? ImportError, .empty)
        }
    }
}
