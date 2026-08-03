import XCTest
import ReaderCore
@testable import Reader

final class EPUBImporterTests: XCTestCase {
    private func chapters(_ url: URL) async throws -> [Chapter] {
        try await EPUBImporter(url: url).chapters()
    }

    func testSpineDeterminesReadingOrderNotManifestOrder() async throws {
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

    func testReportsParsingProgressPerSpineItem() async throws {
        let url = try Fixture.simpleEPUB(["ALPHA", "BRAVO", "CHARLIE"])
        let progress = ImportProgressRecorder()
        _ = try await EPUBImporter(url: url, onParsingProgress: progress.record).chapters()
        XCTAssertEqual(progress.values, [
            ImportProgressSample(completed: 0, total: 3),
            ImportProgressSample(completed: 1, total: 3),
            ImportProgressSample(completed: 2, total: 3),
            ImportProgressSample(completed: 3, total: 3),
        ])
    }

    func testLinearNoItemsAreSkipped() async throws {
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
        XCTAssertTrue(text.contains("あ"), text)
        XCTAssertTrue(text.contains("x y"), text)
        XCTAssertFalse(text.contains("&amp;"), text)
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
        let body = "<p><ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>は難しい</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let text = try await chapters(url)[0].text
        XCTAssertEqual(text, "漢字は難しい")
        XCTAssertFalse(text.contains("かんじ"), text)
    }

    func testKeepsRubyReadingsAsSourceAnnotations() async throws {
        let body = "<p><ruby><rb>黄</rb><rt>おう</rt><rb>前</rb><rt>まえ</rt></ruby>久美子</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let chapter = try await chapters(url)[0]

        XCTAssertEqual(chapter.text, "黄前久美子", "the reading must not be inlined")
        XCTAssertEqual(chapter.sourceReadings.map(\.surface), ["黄", "前"])
        XCTAssertEqual(chapter.sourceReadings.map(\.reading), ["おう", "まえ"])
        for r in chapter.sourceReadings {
            let chars = Array(chapter.text)
            XCTAssertEqual(String(chars[r.start..<r.end]), r.surface)
        }
    }

    func testKeepsRubyWithAnImplicitBase() async throws {
        let body = "<p><ruby>漢字<rp>(</rp><rt>かんじ</rt><rp>)</rp></ruby>は難しい</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let chapter = try await chapters(url)[0]

        XCTAssertEqual(chapter.text, "漢字は難しい")
        XCTAssertEqual(chapter.sourceReadings.count, 1)
        XCTAssertEqual(chapter.sourceReadings.first?.surface, "漢字")
        XCTAssertEqual(chapter.sourceReadings.first?.reading, "かんじ")
        XCTAssertEqual(chapter.sourceReadings.first?.start, 0)
    }

    func testKeepsEveryPairOfAMultiSegmentImplicitRuby() async throws {
        let body = "<p><ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>を読む</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let chapter = try await chapters(url)[0]

        XCTAssertEqual(chapter.text, "漢字を読む", "a base was dropped from the text")
        XCTAssertEqual(chapter.sourceReadings.map(\.surface), ["漢", "字"])
        XCTAssertEqual(chapter.sourceReadings.map(\.reading), ["かん", "じ"])
        let chars = Array(chapter.text)
        for r in chapter.sourceReadings {
            XCTAssertEqual(String(chars[r.start..<r.end]), r.surface)
        }
    }

    func testKeepsUnannotatedTailOfAnImplicitRuby() async throws {
        let body = "<p><ruby>黄<rt>おう</rt>前久美子</ruby></p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let chapter = try await chapters(url)[0]

        XCTAssertEqual(chapter.text, "黄前久美子")
        XCTAssertEqual(chapter.sourceReadings.map(\.surface), ["黄"])
    }

    func testMultiCharacterReadingsPropagateAcrossTheBook() async throws {
        let annotated = "<p><ruby><rb>黄</rb><rt>おう</rt><rb>前</rb><rt>まえ</rt></ruby>が来た</p>"
        let bare = "<p>黄前久美子</p>"
        let url = try Fixture.epub(
            manifest: [
                Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: annotated)),
                Fixture.EPUBItem(id: "c1", href: "c1.xhtml", content: Fixture.xhtml(body: bare)),
            ],
            spine: [Fixture.SpineRef("c0"), Fixture.SpineRef("c1")])
        let all = try await chapters(url)

        let second = all[1]
        XCTAssertEqual(second.text, "黄前久美子")
        XCTAssertEqual(second.sourceReadings.map(\.surface), ["黄", "前"],
                       "the reading must reach a chapter that has no ruby at all")
        XCTAssertEqual(second.sourceReadings.map(\.reading), ["おう", "まえ"])
    }

    func testSingleCharacterReadingsDoNotPropagate() async throws {
        let annotated = "<p><ruby><rb>長</rb><rt>た</rt></ruby>けている</p>"
        let elsewhere = "<p>部長は背が長い</p>"
        let url = try Fixture.epub(
            manifest: [
                Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: annotated)),
                Fixture.EPUBItem(id: "c1", href: "c1.xhtml", content: Fixture.xhtml(body: elsewhere)),
            ],
            spine: [Fixture.SpineRef("c0"), Fixture.SpineRef("c1")])
        let all = try await chapters(url)

        XCTAssertEqual(all[0].sourceReadings.map(\.reading), ["た"])
        XCTAssertEqual(all[1].text, "部長は背が長い")
        XCTAssertEqual(all[1].sourceReadings, [],
                       "a one-kanji reading must not be asserted over other contexts")
    }

    func testRubyOffsetsSurviveTheRestOfTheStrip() async throws {
        let body = "<p>  &#x3042;&nbsp;&#x3044;   <b>x</b>\n<ruby><rb>黄</rb><rt>おう</rt></ruby>end</p>"
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml", content: Fixture.xhtml(body: body))],
            spine: [Fixture.SpineRef("c0")])
        let chapter = try await chapters(url)[0]

        let r = try XCTUnwrap(chapter.sourceReadings.first)
        let chars = Array(chapter.text)
        XCTAssertEqual(String(chars[r.start..<r.end]), "黄",
                       "offset drifted; text was \(chapter.text.debugDescription)")
    }

    func testChaptersWithoutRubyCarryNoAnnotations() async throws {
        let url = try Fixture.epub(
            manifest: [Fixture.EPUBItem(id: "c0", href: "c0.xhtml",
                                        content: Fixture.xhtml(body: "<p>ふつうの文</p>"))],
            spine: [Fixture.SpineRef("c0")])
        let chapter = try await chapters(url)[0]
        XCTAssertEqual(chapter.sourceReadings, [])
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
        let url = try Fixture.epub(manifest: manifest, spine: [])
        do {
            _ = try await chapters(url)
            XCTFail("expected empty")
        } catch {
            XCTAssertEqual(error as? ImportError, .empty)
        }
    }

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

    func testImageOnlySpineItemsAreOCRdInOrder() async throws {
        let url = try Fixture.imageEPUB(pages: 2)
        let stub = StubRecognizer(perImage: ["認識A", "認識B"])
        let result = try await EPUBImporter(url: url, recognizer: stub).chapters()
        XCTAssertEqual(result.map(\.text), ["認識A", "認識B"])
        XCTAssertEqual(stub.imageCount, 2)
    }

    func testImageOnlyEPUBWithNoRecognizerThrowsOCRUnavailable() async throws {
        let url = try Fixture.imageEPUB(pages: 2)
        do {
            _ = try await EPUBImporter(url: url).chapters()
            XCTFail("expected ocrUnavailable")
        } catch {
            XCTAssertEqual(error as? ImportError, .ocrUnavailable)
        }
    }

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
        XCTAssertEqual(stub.imageCount, 1)
    }

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

    func testOCRCandidateCountCountsImagePagesOnly() async throws {
        XCTAssertEqual(EPUBImporter(url: try Fixture.imageEPUB(pages: 3)).ocrCandidateCount(), 3)
        XCTAssertEqual(EPUBImporter(url: try Fixture.simpleEPUB(["本文"])).ocrCandidateCount(), 0)
    }

    func testEPUBOCRWindowingPreservesOrderAcrossWindows() async throws {
        let url = try Fixture.imageEPUB(pages: 10)
        let counter = OCRCounter()
        let result = try await EPUBImporter(url: url, recognizer: counter).chapters()
        XCTAssertEqual(result.map(\.text), (0..<10).map { "P\($0)" })
        XCTAssertGreaterThanOrEqual(counter.calls, 2)
    }
}
