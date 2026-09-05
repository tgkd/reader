import XCTest
import UIKit
import ReaderCore
@testable import Reader

@MainActor
final class RubyTapTests: XCTestCase {
    func testFirstWordTapRestoresControlsAndSecondTapDefinesInBothOrientations() throws {
        for vertical in [false, true] {
            let content = RubyContentView(frame: CGRect(x: 0, y: 0, width: 320, height: 500))
            content.configure(
                spans: [TokenSpan(index: 0, surface: "猫", reading: "ねこ",
                                  start: 0, end: 1, matchedChars: 1)],
                structureVersion: 1, activeIndex: nil, vertical: vertical,
                fontName: "HiraMinProN-W3", fontScale: 1, showFurigana: true,
                ink: .black, hi: .yellow)
            var lookedUp: Int?
            content.onTapToken = { lookedUp = $0 }

            var wordPoint: CGPoint?
            outer: for y in stride(from: 0, to: 500, by: 4) {
                for x in stride(from: 0, to: 320, by: 4) {
                    let point = CGPoint(x: x, y: y)
                    content.handleTap(at: point)
                    if lookedUp != nil {
                        wordPoint = point
                        break outer
                    }
                }
            }
            let point = try XCTUnwrap(wordPoint, "Expected a rendered word; vertical=\(vertical)")
            lookedUp = nil
            var restores = 0
            content.onTapBackground = {
                restores += 1
                content.chromeVisible = true
            }
            content.chromeVisible = false

            content.handleTap(at: point)
            XCTAssertTrue(content.chromeVisible)
            XCTAssertEqual(restores, 1)
            XCTAssertNil(lookedUp)

            content.handleTap(at: point)
            XCTAssertEqual(lookedUp, 0)
            XCTAssertEqual(restores, 1)
        }
    }

    func testTapInScrollInsetReachesBackgroundAction() {
        let content = RubyContentView()
        var taps = 0
        content.onTapBackground = { taps += 1 }
        content.handleTap(at: CGPoint(x: -20, y: -64))
        XCTAssertEqual(taps, 1)
    }
}
