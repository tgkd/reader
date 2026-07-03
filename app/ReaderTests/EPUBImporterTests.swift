import XCTest
import ReaderCore
@testable import Reader

/// Exercises the real `EPUBImporter` over generated EPUBs: spine ordering,
/// `linear="no"` skipping, `<head>` isolation, entity decoding, and error cases.
final class EPUBImporterTests: XCTestCase {
    private func chapters(_ url: URL) async throws -> [Chapter] {
        try await EPUBImporter(url: url).chapters()
    }

    func testSpineDeterminesReadingOrderNotManifestOrder() async throws {
        // Manifest declares b, a, c; spine asks for a, b, c — chapters must follow spine.
        let manifest = [
            Fixture.EPUBItem(id: "b", href: "b.xhtml", content: Fixture.xhtml(body: "<p>BRAVO</p>")),
            Fixture.EPUBItem(id: "a", href: "a.xhtml", content: Fixture.xhtml(body: "<p>ALPHA</p>")),
            Fixture.EPUBItem(id: "c", href: "c.xhtml", content: Fixture.xhtml(body: "<p>CHARLIE</p>")),
        ]
        let url = try Fixture.epub(manifest: manifest,
                                   spine: [Fixture.SpineRef("a"), Fixture.SpineRef("b"), Fixture.SpineRef("c")])
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.text), ["ALPHA", "BRAVO", "CHARLIE"])
    }

    func testLinearNoItemsAreSkipped() async throws {
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
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.text), ["BODY1", "BODY2"])
    }

    func testHeadMetadataDoesNotLeakIntoChapter() async throws {
        // <head><title> must never appear in the extracted body text.
        let url = try Fixture.simpleEPUB(["本文だけ"])
        let result = try await chapters(url)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "本文だけ")
        XCTAssertFalse(result[0].text.contains("HEAD_TITLE_DO_NOT_LEAK"))
    }

    func testHtmlEntitiesAreDecoded() async throws {
        let body = "<p>A&amp;B &lt;tag&gt; &#38; &#x3042; x&nbsp;y</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let text = try await chapters(url)[0].text
        XCTAssertTrue(text.contains("A&B"), text)
        XCTAssertTrue(text.contains("<tag>"), text)
        XCTAssertTrue(text.contains("あ"), text)      // &#x3042;
        XCTAssertTrue(text.contains("x y"), text)     // &nbsp; → space
        XCTAssertFalse(text.contains("&amp;"), text)  // no double-encoding left behind
    }

    func testBlockTagsBecomeLineBreaks() async throws {
        let body = "<p>一行目</p><p>二行目</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let text = try await chapters(url)[0].text
        XCTAssertEqual(text, "一行目\n二行目")
    }

    func testRubyReadingsAreNotInlined() async throws {
        // <rt>/<rp> hold the furigana reading; keeping their CONTENT would inline it
        // into the body (漢字かんじ), doubling TTS/tokenization. Only the base survives;
        // the reader draws its own furigana from MeCab.
        let body = "<p><ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>は難しい</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let text = try await chapters(url)[0].text
        XCTAssertEqual(text, "漢字は難しい")
        XCTAssertFalse(text.contains("かんじ"), text)
    }

    func testEmptyBodyItemsAreSkipped() async throws {
        let manifest = [
            Fixture.EPUBItem(id: "a", href: "a.xhtml", content: Fixture.xhtml(body: "<p>REAL</p>")),
            Fixture.EPUBItem(id: "blank", href: "blank.xhtml", content: Fixture.xhtml(body: "")),
        ]
        let url = try Fixture.epub(manifest: manifest,
                                   spine: [Fixture.SpineRef("a"), Fixture.SpineRef("blank")])
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.text), ["REAL"])
    }

    func testNestedAndPercentEncodedHrefResolves() async throws {
        // href in a subdir with a percent-encoded space — the importer decodes it.
        let manifest = [Fixture.EPUBItem(id: "c0", href: "text/ch%201.xhtml",
                                         content: Fixture.xhtml(body: "<p>NESTED</p>"))]
        let url = try Fixture.epub(manifest: manifest, spine: [Fixture.SpineRef("c0")])
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.text), ["NESTED"])
    }

    func testCorruptArchiveThrowsUnreadable() async {
        let url = Fixture.write(Data("not a zip".utf8), ext: "epub")
        do {
            _ = try await chapters(url)
            XCTFail("expected unreadable")
        } catch {
            XCTAssertEqual(error as? ImportError, .unreadable)
        }
    }

    func testEmptySpineThrowsEmpty() async throws {
        let manifest = [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: "<p>X</p>"))]
        let url = try Fixture.epub(manifest: manifest, spine: [])   // declared but no itemrefs
        do {
            _ = try await chapters(url)
            XCTFail("expected empty")
        } catch {
            XCTAssertEqual(error as? ImportError, .empty)
        }
    }

    // MARK: - TOC chapter titles (EPUB3 nav / EPUB2 NCX)

    func testNavTOCTitlesMapToSpineChapters() async throws {
        let manifest = [
            Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: "<p>ONE</p>")),
            Fixture.EPUBItem(id: "c1", href: "c1.xhtml", content: Fixture.xhtml(body: "<p>TWO</p>")),
            Fixture.EPUBItem(id: "nav", href: "nav.xhtml",
                             content: Fixture.navDoc([("c0.xhtml", "第一章"), ("c1.xhtml", "第二章")]),
                             properties: "nav"),
        ]
        let url = try Fixture.epub(manifest: manifest,
                                   spine: [Fixture.SpineRef("c0"), Fixture.SpineRef("c1")])
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.title), ["第一章", "第二章"])
        XCTAssertEqual(result.map(\.text), ["ONE", "TWO"])
    }

    func testNCXTitlesUsedWhenNoNavDoc() async throws {
        let manifest = [
            Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: "<p>ONE</p>")),
            Fixture.EPUBItem(id: "ncx", href: "toc.ncx",
                             content: Fixture.ncx([("c0.xhtml", "序章")]),
                             mediaType: "application/x-dtbncx+xml"),
        ]
        let url = try Fixture.epub(manifest: manifest, spine: [Fixture.SpineRef("c0")],
                                   spineTOC: "ncx")
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.title), ["序章"])
        XCTAssertFalse(result[0].text.contains("DOC_TITLE_DO_NOT_LEAK"))
    }

    func testNavDocPreferredOverNCX() async throws {
        let manifest = [
            Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: "<p>ONE</p>")),
            Fixture.EPUBItem(id: "nav", href: "nav.xhtml",
                             content: Fixture.navDoc([("c0.xhtml", "NAVタイトル")]),
                             properties: "nav"),
            Fixture.EPUBItem(id: "ncx", href: "toc.ncx",
                             content: Fixture.ncx([("c0.xhtml", "NCXタイトル")]),
                             mediaType: "application/x-dtbncx+xml"),
        ]
        let url = try Fixture.epub(manifest: manifest, spine: [Fixture.SpineRef("c0")],
                                   spineTOC: "ncx")
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.title), ["NAVタイトル"])
    }

    func testTOCFragmentHrefsMapToFileFirstWins() async throws {
        // Two anchors into one file: the chapter takes the FIRST (chapter-opening) title.
        let manifest = [
            Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: "<p>ONE</p>")),
            Fixture.EPUBItem(id: "nav", href: "nav.xhtml",
                             content: Fixture.navDoc([("c0.xhtml#intro", "始まり"),
                                                      ("c0.xhtml#part2", "続き")]),
                             properties: "nav"),
        ]
        let url = try Fixture.epub(manifest: manifest, spine: [Fixture.SpineRef("c0")])
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.title), ["始まり"])
    }

    func testTOCHrefsResolveRelativeToTOCDirectory() async throws {
        // Nav doc in a subdirectory: its hrefs are relative to ITS directory, not the OPF's.
        let manifest = [
            Fixture.EPUBItem(id: "c0", href: "text/c0.xhtml", content: Fixture.xhtml(body: "<p>ONE</p>")),
            Fixture.EPUBItem(id: "nav", href: "nav/toc.xhtml",
                             content: Fixture.navDoc([("../text/c0.xhtml", "奥付")]),
                             properties: "nav"),
        ]
        let url = try Fixture.epub(manifest: manifest, spine: [Fixture.SpineRef("c0")])
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.title), ["奥付"])
    }

    func testPartialTOCLeavesUnlistedChaptersUntitled() async throws {
        let manifest = [
            Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: "<p>ONE</p>")),
            Fixture.EPUBItem(id: "c1", href: "c1.xhtml", content: Fixture.xhtml(body: "<p>TWO</p>")),
            Fixture.EPUBItem(id: "nav", href: "nav.xhtml",
                             content: Fixture.navDoc([("c1.xhtml", "第二章")]),
                             properties: "nav"),
        ]
        let url = try Fixture.epub(manifest: manifest,
                                   spine: [Fixture.SpineRef("c0"), Fixture.SpineRef("c1")])
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.title), [nil, "第二章"])
    }

    func testMissingTOCYieldsNilTitles() async throws {
        // No nav doc, no NCX — every chapter stays untitled (regression guard).
        let result = try await chapters(try Fixture.simpleEPUB(["ONE", "TWO"]))
        XCTAssertEqual(result.map(\.title), [nil, nil])
    }

    func testNavLabelTagsStrippedAndEntitiesDecoded() async throws {
        let manifest = [
            Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: "<p>ONE</p>")),
            Fixture.EPUBItem(id: "nav", href: "nav.xhtml",
                             content: Fixture.navDoc([("c0.xhtml", "<span>第一章</span>&amp;序")]),
                             properties: "nav"),
        ]
        let url = try Fixture.epub(manifest: manifest, spine: [Fixture.SpineRef("c0")])
        let result = try await chapters(url)
        XCTAssertEqual(result.map(\.title), ["第一章&序"])
    }

    // MARK: - OCR fallback (image-only spine items)

    /// A spine item whose text is baked into an `<img>` is OCR'd; recovered text becomes
    /// the chapter, in spine order. The referenced image is pulled from the archive.
    func testImageOnlySpineItemsAreOCRdInOrder() async throws {
        let url = try Fixture.imageEPUB(pages: 2)
        let stub = StubRecognizer(perImage: ["認識A", "認識B"])
        let result = try await EPUBImporter(url: url, recognizer: stub).chapters()
        XCTAssertEqual(result.map(\.text), ["認識A", "認識B"])
        XCTAssertEqual(stub.imageCount, 2)
    }

    /// Non-subscriber (no recognizer): an image-only book recovers no text and throws
    /// `.ocrUnavailable` — the Membership prompt (mirrors PDFImporter), not the
    /// misleading "file is empty". A genuinely empty book still throws `.empty`.
    func testImageOnlyEPUBWithNoRecognizerThrowsOCRUnavailable() async throws {
        let url = try Fixture.imageEPUB(pages: 2)
        do {
            _ = try await EPUBImporter(url: url).chapters()
            XCTFail("expected ocrUnavailable")
        } catch {
            XCTAssertEqual(error as? ImportError, .ocrUnavailable)
        }
    }

    /// Text pages extract locally; image pages OCR — interleaved, in spine order. Only
    /// the image page invokes the recognizer.
    func testMixedTextAndImagePagesInterleaveInOrder() async throws {
        let manifest = [
            Fixture.EPUBItem(id: "t0", href: "t0.xhtml", content: Fixture.xhtml(body: "<p>テキスト頁</p>")),
            Fixture.EPUBItem(id: "i0", href: "i0.xhtml", content: Fixture.xhtml(body: "<img src=\"images/a.jpg\"/>")),
            Fixture.EPUBItem(id: "t1", href: "t1.xhtml", content: Fixture.xhtml(body: "<p>最終頁</p>")),
        ]
        let url = try Fixture.epub(manifest: manifest,
                                   spine: manifest.map { Fixture.SpineRef($0.id) },
                                   extraFiles: ["images/a.jpg": Fixture.jpeg("X")])
        let stub = StubRecognizer(perImage: ["画像頁"])
        let result = try await EPUBImporter(url: url, recognizer: stub).chapters()
        XCTAssertEqual(result.map(\.text), ["テキスト頁", "画像頁", "最終頁"])
        XCTAssertEqual(stub.imageCount, 1)   // only the image page hit OCR
    }

    /// OCR recovering nothing from the image pages throws `.ocrFailed` (mirrors PDF).
    func testImageEPUBOCRYieldingNothingThrowsOCRFailed() async throws {
        let url = try Fixture.imageEPUB(pages: 2)
        let stub = StubRecognizer(perImage: ["", "   "])
        do {
            _ = try await EPUBImporter(url: url, recognizer: stub).chapters()
            XCTFail("expected ocrFailed")
        } catch {
            XCTAssertEqual(error as? ImportError, .ocrFailed)
        }
    }

    /// The probe counts image pages without OCR; text pages don't count.
    func testOCRCandidateCountCountsImagePagesOnly() async throws {
        XCTAssertEqual(EPUBImporter(url: try Fixture.imageEPUB(pages: 3)).ocrCandidateCount(), 3)
        XCTAssertEqual(EPUBImporter(url: try Fixture.simpleEPUB(["本文"])).ocrCandidateCount(), 0)
    }

    /// More image pages than the OCR window → multiple recognize passes; recovered text
    /// stays in global page order across windows (bounded-memory windowing).
    func testEPUBOCRWindowingPreservesOrderAcrossWindows() async throws {
        let url = try Fixture.imageEPUB(pages: 10)
        let counter = OCRCounter()
        let result = try await EPUBImporter(url: url, recognizer: counter).chapters()
        XCTAssertEqual(result.map(\.text), (0..<10).map { "P\($0)" })
        XCTAssertGreaterThanOrEqual(counter.calls, 2)   // processed in >1 window
    }
}
