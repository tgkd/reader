import XCTest
import CoreText
import UIKit
@testable import Reader

final class RubyLineBreakTests: XCTestCase {
    private static let base = "無い"
    private static let lead = "名前はまだ"
    private static let tail = "。どこで"

    private func splitsBase(width: CGFloat, joinBase: Bool) -> Bool {
        let font = UIFont(name: "HiraMinProN-W3", size: 34) ?? .systemFont(ofSize: 34)
        let rubyFont = UIFont(name: "HiraMinProN-W3", size: 17) ?? .systemFont(ofSize: 17)
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: Self.lead, attributes: [.font: font]))

        let shown = joinBase ? RubyContentView.wordJoined(Self.base) : Self.base
        let piece = NSMutableAttributedString(string: shown, attributes: [.font: font])
        let ann = CTRubyAnnotationCreateWithAttributes(
            .center, .auto, .before, "ない" as CFString,
            [kCTFontAttributeName: rubyFont] as CFDictionary)
        piece.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                           value: ann, range: NSRange(location: 0, length: piece.length))
        let baseRange = NSRange(location: out.length, length: piece.length)
        out.append(piece)
        out.append(NSAttributedString(string: Self.tail, attributes: [.font: font]))

        let fs = CTFramesetterCreateWithAttributedString(out)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 600), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil)
        for line in CTFrameGetLines(frame) as! [CTLine] {
            let r = CTLineGetStringRange(line)
            let lineRange = NSRange(location: r.location, length: r.length)
            let overlap = NSIntersectionRange(baseRange, lineRange)
            if overlap.length > 0 && overlap.length < baseRange.length { return true }
        }
        return false
    }

    private var widths: [CGFloat] { stride(from: 180.0, through: 320.0, by: 10.0).map { $0 } }

    func testUnjoinedBaseSplitsAtSomeWidth() {
        XCTAssertTrue(widths.contains { splitsBase(width: $0, joinBase: false) },
                      "Expected CoreText to break inside the ruby base at some width")
    }

    func testJoinedBaseNeverSplits() {
        for width in widths {
            XCTAssertFalse(splitsBase(width: width, joinBase: true),
                           "Ruby base split at width \(width) despite WORD JOINER")
        }
    }

    func testJoinerIsPurelyAdditive() {
        let joined = RubyContentView.wordJoined("見当")
        XCTAssertEqual(joined.replacingOccurrences(of: "\u{2060}", with: ""), "見当")
        XCTAssertNotEqual(joined, "見当")
        XCTAssertEqual(RubyContentView.wordJoined("見"), "見")
    }
}
