import XCTest
import CoreGraphics
@testable import Reader

/// `ReadingOrder` is a pure function over OCR bounding boxes (no Vision), so these
/// assert ordering deterministically. Boxes use the Vision convention: normalized
/// (0…1), origin BOTTOM-LEFT (larger y = higher on the page).
final class ReadingOrderTests: XCTestCase {

    private func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    func testEmptyIsEmpty() {
        XCTAssertEqual(ReadingOrder.assemble([]), "")
    }

    func testSingleObservation() {
        XCTAssertEqual(ReadingOrder.assemble([("こんにちは", box(0.1, 0.5, 0.5, 0.05))]), "こんにちは")
    }

    /// Wide line-boxes → horizontal: rows top→bottom, within a row left→right.
    /// Input is shuffled to prove it's geometry, not input order.
    func testHorizontalRowsTopToBottomLeftToRight() {
        let boxes: [(text: String, box: CGRect)] = [
            ("い", box(0.4, 0.80, 0.2, 0.05)),   // top row, right
            ("う", box(0.1, 0.20, 0.2, 0.05)),   // bottom row, left
            ("あ", box(0.1, 0.80, 0.2, 0.05)),   // top row, left
            ("え", box(0.4, 0.20, 0.2, 0.05)),   // bottom row, right
        ]
        XCTAssertEqual(ReadingOrder.assemble(boxes), "あい\nうえ")
    }

    /// Tall line-boxes → vertical (縦書き): columns RIGHT→LEFT, within a column
    /// top→bottom. Reading order is 一二 (right column) then 三四 (left).
    func testVerticalColumnsRightToLeftTopToBottom() {
        let boxes: [(text: String, box: CGRect)] = [
            ("四", box(0.26, 0.55, 0.08, 0.12)),   // left column, lower
            ("一", box(0.66, 0.75, 0.08, 0.12)),   // right column, upper
            ("三", box(0.26, 0.75, 0.08, 0.12)),   // left column, upper
            ("二", box(0.66, 0.55, 0.08, 0.12)),   // right column, lower
        ]
        XCTAssertEqual(ReadingOrder.assemble(boxes), "一二\n三四")
    }

    /// A single horizontal line stays one line (no spurious column split).
    func testSingleHorizontalLine() {
        let boxes: [(text: String, box: CGRect)] = [
            ("世界", box(0.4, 0.5, 0.25, 0.05)),
            ("こんにちは", box(0.1, 0.5, 0.25, 0.05)),
        ]
        XCTAssertEqual(ReadingOrder.assemble(boxes), "こんにちは世界")
    }
}
