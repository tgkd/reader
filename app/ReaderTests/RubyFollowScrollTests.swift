import XCTest
import UIKit
import ReaderCore
@testable import Reader

final class RubyFollowScrollTests: XCTestCase {
    private func makeSpans(targetChars: Int) -> [TokenSpan] {
        let vocabulary: [(String, String?)] = [
            ("吾輩", "わがはい"), ("は", nil), ("猫", "ねこ"), ("である", nil), ("。", nil),
            ("名前", "なまえ"), ("は", nil), ("まだ", nil), ("無い", "ない"), ("。", nil),
            ("どこ", nil), ("で", nil), ("生れた", "うまれた"), ("か", nil),
            ("頓と", "とんと"), ("見当", "けんとう"), ("が", nil), ("つかぬ", nil), ("。", nil),
        ]
        var spans: [TokenSpan] = []
        var chars = 0
        var i = 0
        while chars < targetChars {
            let (surface, reading) = vocabulary[i % vocabulary.count]
            spans.append(TokenSpan(index: spans.count, surface: surface, reading: reading,
                                   start: 0, end: 0, matchedChars: surface.count))
            chars += surface.count
            i += 1
        }
        return spans
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private struct Outcome {
        let drift: CGFloat
        let parked: CGFloat
    }

    private func scrollAway(activeIndex: Int?, vertical: Bool, byDragging: Bool,
                            thenAdvanceHighlightTo advanced: Int? = nil) -> Outcome {
        let spans = makeSpans(targetChars: 4000)
        let id = UUID()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        let sv = RubyScrollView()
        sv.frame = window.bounds
        window.addSubview(sv)
        window.isHidden = false

        func apply(_ active: Int?) {
            sv.configure(spans: spans, structureVersion: 1, activeIndex: active,
                         vertical: vertical, chapterID: id, initialToken: nil,
                         fontName: "HiraMinProN-W3", fontScale: 1, showFurigana: true,
                         topInset: 64, bottomInset: 88, ink: .black, hi: .yellow)
            sv.layoutIfNeeded()
        }

        apply(activeIndex)
        sv.content.layer.displayIfNeeded()

        let extent = vertical
            ? sv.contentSize.width - sv.bounds.width
            : sv.contentSize.height - sv.bounds.height
        let parked = vertical ? extent * 0.5 : extent * 0.75

        if byDragging { sv.scrollViewWillBeginDragging(sv) }
        sv.contentOffset = vertical ? CGPoint(x: parked, y: 0) : CGPoint(x: 0, y: parked)
        sv.layoutIfNeeded()
        if byDragging { sv.scrollViewDidEndDragging(sv, willDecelerate: false) }

        apply(advanced ?? activeIndex)
        pump(0.6)

        let after = vertical ? sv.contentOffset.x : sv.contentOffset.y
        window.isHidden = true
        return Outcome(drift: abs(after - parked), parked: parked)
    }

    func testChapterWithNoAudioStaysWhereTheUserScrolled() {
        for vertical in [false, true] {
            let r = scrollAway(activeIndex: nil, vertical: vertical, byDragging: true)
            print("NO-AUDIO vertical=\(vertical) parked=\(Int(r.parked)) drift=\(Int(r.drift))pt")
            XCTAssertLessThan(r.drift, 1,
                              "drifted \(r.drift)pt with no highlight (vertical=\(vertical))")
        }
    }

    func testManualDragIsNotUndoneByTheFollowLink() {
        for vertical in [false, true] {
            let r = scrollAway(activeIndex: 4, vertical: vertical, byDragging: true)
            print("DRAGGED vertical=\(vertical) parked=\(Int(r.parked)) drift=\(Int(r.drift))pt")
            XCTAssertLessThan(r.drift, 1,
                              "the follow link pulled the reader back \(r.drift)pt after a manual "
                              + "drag (vertical=\(vertical))")
        }
    }

    func testFollowStillCentersHighlightWhenUserHasNotScrolled() {
        for vertical in [false, true] {
            let r = scrollAway(activeIndex: 4, vertical: vertical, byDragging: false)
            print("AUTOSCROLL vertical=\(vertical) parked=\(Int(r.parked)) drift=\(Int(r.drift))pt")
            XCTAssertGreaterThan(r.drift, 50,
                                 "auto-scroll no longer follows the highlight (vertical=\(vertical))")
        }
    }

    func testFollowResumesOnceThePlayheadMovesOn() {
        for vertical in [false, true] {
            let r = scrollAway(activeIndex: 4, vertical: vertical, byDragging: true,
                               thenAdvanceHighlightTo: 5)
            print("RESUMED vertical=\(vertical) parked=\(Int(r.parked)) drift=\(Int(r.drift))pt")
            XCTAssertGreaterThan(r.drift, 50,
                                 "follow did not resume after the highlight advanced "
                                 + "(vertical=\(vertical))")
        }
    }
}
