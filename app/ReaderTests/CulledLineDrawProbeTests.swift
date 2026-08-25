import XCTest
import CoreText
import UIKit
@testable import Reader

final class CulledLineDrawProbeTests: XCTestCase {
    private func attributed(vertical: Bool, paragraphs: Int) -> NSAttributedString {
        let font = UIFont(name: "HiraMinProN-W3", size: 26) ?? .systemFont(ofSize: 26)
        let rubyFont = UIFont(name: "HiraMinProN-W3", size: 13) ?? .systemFont(ofSize: 13)
        let out = NSMutableAttributedString()
        let words: [(String, String?)] = [
            ("吾輩", "わがはい"), ("は", nil), ("猫", "ねこ"), ("である", nil), ("。", nil),
            ("名前", "なまえ"), ("は", nil), ("まだ", nil), ("無い", "ない"), ("。", nil),
        ]
        for i in 0..<paragraphs {
            let (surface, reading) = words[i % words.count]
            let piece = NSMutableAttributedString(string: surface, attributes: [.font: font])
            if let reading {
                let ann = CTRubyAnnotationCreateWithAttributes(
                    .center, .auto, .before, reading as CFString,
                    [kCTFontAttributeName: rubyFont] as CFDictionary)
                piece.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                                   value: ann, range: NSRange(location: 0, length: piece.length))
            }
            out.append(piece)
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = vertical ? 1.0 : 1.2
        let whole = NSRange(location: 0, length: out.length)
        out.addAttributes([.paragraphStyle: para], range: whole)
        if vertical {
            out.addAttribute(NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
                             value: true, range: whole)
        }
        return out
    }

    private func makeFrame(_ text: NSAttributedString, vertical: Bool, size: CGSize)
        -> (CTFrame, [CTLine], [CGPoint]) {
        let fs = CTFramesetterCreateWithAttributedString(text)
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        let attrs: CFDictionary? = vertical
            ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
            : nil
        let frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, attrs)
        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins) }
        return (frame, lines, origins)
    }

    private func render(size: CGSize, _ body: (CGContext) -> Void) -> [UInt8] {
        let w = Int(size.width), h = Int(size.height)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.textMatrix = .identity
            ctx.setFillColor(UIColor.black.cgColor)
            body(ctx)
        }
        return pixels
    }

    private func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var n = 0
        for i in stride(from: 0, to: a.count, by: 4) where a[i] != b[i] { n += 1 }
        return n
    }

    private func probe(vertical: Bool) -> (total: Int, differing: Int, lines: Int) {
        let size = CGSize(width: 340, height: 620)
        let text = attributed(vertical: vertical, paragraphs: 260)
        let (frame, lines, origins) = makeFrame(text, vertical: vertical, size: size)

        let whole = render(size: size) { ctx in
            CTFrameDraw(frame, ctx)
        }
        let perLine = render(size: size) { ctx in
            for (i, line) in lines.enumerated() {
                ctx.textPosition = origins[i]
                CTLineDraw(line, ctx)
            }
        }
        return (size.width.hashValue == 0 ? 0 : Int(size.width * size.height),
                differingPixels(whole, perLine), lines.count)
    }

    func testPerLineDrawMatchesFrameDrawHorizontally() {
        let r = probe(vertical: false)
        let pct = Double(r.differing) / Double(r.total) * 100
        print("CULL-PROBE horizontal lines=\(r.lines) differing=\(r.differing)/\(r.total) "
              + "(\(String(format: "%.2f", pct))%)")
        XCTAssertLessThan(pct, 0.1, "per-line drawing diverges from CTFrameDraw horizontally")
    }

    func testTileClippedFrameDrawAtProductionChapterSize() {
        for (vertical, size) in [(false, CGSize(width: 333, height: 14888)),
                                 (true, CGSize(width: 8437, height: 700))] {
            let text = attributed(vertical: vertical, paragraphs: 2000)
            let (frame, lines, _) = makeFrame(text, vertical: vertical, size: size)

            let tile = CGSize(width: 512, height: 512)
            var slowest = 0.0
            var total = 0.0
            var tiles = 0
            var y = 0.0
            while y < size.height {
                var x = 0.0
                while x < size.width {
                    let t = CFAbsoluteTimeGetCurrent()
                    _ = render(size: tile) { ctx in
                        ctx.translateBy(x: -x, y: -(size.height - y - tile.height))
                        CTFrameDraw(frame, ctx)
                    }
                    let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
                    slowest = max(slowest, ms)
                    total += ms
                    tiles += 1
                    x += tile.width
                }
                y += tile.height
            }
            let screenful = vertical
                ? ceil(393 / tile.width) * ceil(852 / tile.height)
                : ceil(393 / tile.width) * ceil(852 / tile.height)
            print("PROD-TILE vertical=\(vertical) lines=\(lines.count) tiles=\(tiles) "
                  + "slowestTile=\(String(format: "%.1f", slowest))ms "
                  + "avgTile=\(String(format: "%.1f", total / Double(tiles)))ms "
                  + "wholeChapter=\(String(format: "%.0f", total))ms "
                  + "perScreenful=\(String(format: "%.1f", total / Double(tiles) * screenful))ms")
            XCTAssertLessThan(total / Double(tiles), 30,
                              "average tile too slow to keep up with scrolling (vertical=\(vertical))")
        }
    }

    func testPerLineDrawMatchesFrameDrawVertically() {
        let r = probe(vertical: true)
        let pct = Double(r.differing) / Double(r.total) * 100
        print("CULL-PROBE vertical lines=\(r.lines) differing=\(r.differing)/\(r.total) "
              + "(\(String(format: "%.2f", pct))%)")
        XCTAssertGreaterThan(pct, 1,
                             "per-line drawing now matches vertically — the tile path can be simplified")
    }
}
