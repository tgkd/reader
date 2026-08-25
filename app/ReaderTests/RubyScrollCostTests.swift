import XCTest
import UIKit
import ReaderCore
@testable import Reader

final class RubyScrollCostTests: XCTestCase {
    private static let vocabulary: [(String, String?)] = [
        ("吾輩", "わがはい"), ("は", nil), ("猫", "ねこ"), ("である", nil), ("。", nil),
        ("名前", "なまえ"), ("は", nil), ("まだ", nil), ("無い", "ない"), ("。", nil),
        ("どこ", nil), ("で", nil), ("生れた", "うまれた"), ("か", nil),
        ("頓と", "とんと"), ("見当", "けんとう"), ("が", nil), ("つかぬ", nil), ("。", nil),
        ("何でも", "なんでも"), ("薄暗い", "うすぐらい"), ("じめじめ", nil), ("した", nil),
        ("所", "ところ"), ("で", nil), ("ニャーニャー", nil), ("泣いて", "ないて"),
        ("いた事", "いたこと"), ("だけ", nil), ("は", nil), ("記憶", "きおく"),
        ("して", nil), ("いる", nil), ("。", nil),
    ]

    private func makeSpans(targetChars: Int) -> [TokenSpan] {
        var spans: [TokenSpan] = []
        var chars = 0
        var i = 0
        while chars < targetChars {
            let (surface, reading) = Self.vocabulary[i % Self.vocabulary.count]
            spans.append(TokenSpan(index: spans.count, surface: surface, reading: reading,
                                   start: 0, end: 0, matchedChars: surface.count))
            chars += surface.count
            i += 1
        }
        return spans
    }

    private func makeView(vertical: Bool, spans: [TokenSpan], fontScale: CGFloat = 1,
                          topInset: CGFloat = 64, bottomInset: CGFloat = 88,
                          chapterID: UUID = UUID())
        -> (UIWindow, RubyScrollView) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let sv = RubyScrollView()
        sv.frame = window.bounds
        window.addSubview(sv)
        window.isHidden = false
        sv.configure(spans: spans, structureVersion: 1, activeIndex: nil, vertical: vertical,
                     chapterID: chapterID, initialToken: nil,
                     fontName: "HiraMinProN-W3", fontScale: fontScale, showFurigana: true,
                     topInset: topInset, bottomInset: bottomInset,
                     ink: .black, hi: .yellow)
        sv.layoutIfNeeded()
        return (window, sv)
    }

    private func millis(_ block: () -> Void) -> Double {
        let t = CFAbsoluteTimeGetCurrent()
        block()
        return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }

    func testScrollingSchedulesNoRedraw() {
        let spans = makeSpans(targetChars: 4000)
        for vertical in [false, true] {
            let (window, sv) = makeView(vertical: vertical, spans: spans)
            defer { window.isHidden = true }

            sv.content.layer.displayIfNeeded()
            XCTAssertFalse(sv.content.layer.needsDisplay(),
                           "content still dirty after initial display (vertical=\(vertical))")

            let extent = vertical
                ? sv.contentSize.width - sv.bounds.width
                : sv.contentSize.height - sv.bounds.height
            guard extent > 0 else {
                XCTFail("chapter did not overflow the viewport (vertical=\(vertical))")
                continue
            }

            var redraws = 0
            let steps = 40
            for s in 1...steps {
                let p = extent * CGFloat(s) / CGFloat(steps)
                sv.contentOffset = vertical ? CGPoint(x: p, y: 0) : CGPoint(x: 0, y: p)
                sv.layoutIfNeeded()
                if sv.content.layer.needsDisplay() {
                    redraws += 1
                    sv.content.layer.displayIfNeeded()
                }
            }
            print("SCROLL vertical=\(vertical) extent=\(Int(extent))pt redraws=\(redraws)/\(steps)")
            XCTAssertEqual(redraws, 0,
                           "scrolling scheduled \(redraws) redraws (vertical=\(vertical))")
        }
    }

    func testChapterOpenCost() {
        let spans = makeSpans(targetChars: 4000)
        for vertical in [false, true] {
            for scale in [CGFloat(1), CGFloat(1.2)] {
                var build = 0.0
                var raster = 0.0
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
                let sv = RubyScrollView()
                sv.frame = window.bounds
                window.addSubview(sv)
                window.isHidden = false
                build = millis {
                    sv.configure(spans: spans, structureVersion: 1, activeIndex: nil,
                                 vertical: vertical, chapterID: UUID(), initialToken: nil,
                                 fontName: "HiraMinProN-W3", fontScale: scale, showFurigana: true,
                                 topInset: 64, bottomInset: 88, ink: .black, hi: .yellow)
                    sv.layoutIfNeeded()
                }
                raster = millis { sv.content.layer.displayIfNeeded() }
                let size = sv.content.bounds.size
                print("OPEN vertical=\(vertical) scale=\(scale) build=\(String(format: "%.1f", build))ms "
                      + "raster=\(String(format: "%.1f", raster))ms "
                      + "layer=\(Int(size.width))x\(Int(size.height))pt "
                      + "px=\(Int(size.width * 3))x\(Int(size.height * 3))")
                window.isHidden = true
            }
        }
    }

    func testInsetOnlyChangeCost() {
        let spans = makeSpans(targetChars: 4000)
        for vertical in [false, true] {
            let id = UUID()
            let (window, sv) = makeView(vertical: vertical, spans: spans, chapterID: id)
            defer { window.isHidden = true }
            sv.content.layer.displayIfNeeded()

            let reconfigure = millis {
                sv.configure(spans: spans, structureVersion: 1, activeIndex: nil,
                             vertical: vertical, chapterID: id,
                             initialToken: nil,
                             fontName: "HiraMinProN-W3", fontScale: 1, showFurigana: true,
                             topInset: 64, bottomInset: 0, ink: .black, hi: .yellow)
                sv.layoutIfNeeded()
            }
            let raster = millis { sv.content.layer.displayIfNeeded() }
            print("INSET vertical=\(vertical) reconfigure=\(String(format: "%.1f", reconfigure))ms "
                  + "raster=\(String(format: "%.1f", raster))ms")
        }
    }

    func testIdenticalReconfigureIsCheap() {
        let spans = makeSpans(targetChars: 4000)
        let id = UUID()
        let (window, sv) = makeView(vertical: true, spans: spans, chapterID: id)
        defer { window.isHidden = true }
        sv.content.layer.displayIfNeeded()

        let repeated = millis {
            for _ in 0..<60 {
                sv.configure(spans: spans, structureVersion: 1, activeIndex: nil, vertical: true,
                             chapterID: id, initialToken: nil,
                             fontName: "HiraMinProN-W3", fontScale: 1, showFurigana: true,
                             topInset: 64, bottomInset: 88, ink: .black, hi: .yellow)
                sv.layoutIfNeeded()
            }
        }
        print("RECONFIGURE x60 total=\(String(format: "%.1f", repeated))ms "
              + "per=\(String(format: "%.3f", repeated / 60))ms")
        XCTAssertLessThan(repeated / 60, 1.0,
                          "an unchanged updateUIView costs \(repeated / 60)ms")
    }

    func testLayerSizeAgainstTextureLimitAcrossCaps() {
        let limit = 16384
        for cap in [1000, 2000, 3000, 4000] {
            let spans = makeSpans(targetChars: cap)
            for vertical in [false, true] {
                let (window, sv) = makeView(vertical: vertical, spans: spans, fontScale: 1.2)
                let size = sv.content.bounds.size
                let major = Int((vertical ? size.width : size.height) * 3)
                let mb = Int(size.width * 3 * size.height * 3 * 4 / 1_048_576)
                print("CAP=\(cap) vertical=\(vertical) major=\(major)px "
                      + "limit=\(limit) fits=\(major <= limit) backing=\(mb)MB")
                window.isHidden = true
            }
        }
    }
}
