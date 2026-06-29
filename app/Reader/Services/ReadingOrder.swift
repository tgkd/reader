import CoreGraphics

/// Reassembles OCR text observations into natural reading order from their bounding
/// boxes. Kept a PURE function over `[(text, box)]` (no Vision types) so it's
/// deterministic and unit-testable without running the recognizer.
///
/// Boxes use the Vision convention: NORMALIZED (0…1) with origin BOTTOM-LEFT, so a
/// larger `y`/`midY` is HIGHER on the page. Best-effort only: it classifies the
/// page as vertical (縦書き) or horizontal by box shape, then clusters observations
/// into columns / rows by geometry and orders them. It cannot reliably untangle
/// multi-column layouts, tables, or ruby kana that sit beside their base text —
/// those are the motivation for the Worker enhanced path.
enum ReadingOrder {
    /// Order `boxes` into a single string (lines/columns separated by newlines).
    static func assemble(_ boxes: [(text: String, box: CGRect)]) -> String {
        guard !boxes.isEmpty else { return "" }
        return isVertical(boxes) ? vertical(boxes) : horizontal(boxes)
    }

    /// Vertical text reads as TALL line-boxes (height > width). If most boxes are
    /// tall, treat the page as 縦書き.
    private static func isVertical(_ boxes: [(text: String, box: CGRect)]) -> Bool {
        let tall = boxes.filter { $0.box.height > $0.box.width }.count
        return Double(tall) / Double(boxes.count) > 0.6
    }

    /// Horizontal: cluster into rows by vertical center, rows top→bottom, within a
    /// row left→right.
    private static func horizontal(_ boxes: [(text: String, box: CGRect)]) -> String {
        let tol = median(boxes.map { $0.box.height }) * 0.5
        var rows: [[(text: String, box: CGRect)]] = []
        for item in boxes.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let i = rows.firstIndex(where: { abs($0[0].box.midY - item.box.midY) < tol }) {
                rows[i].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows
            .sorted { rowCenter($0, \.box.midY) > rowCenter($1, \.box.midY) }   // top → bottom
            .map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined() }
            .joined(separator: "\n")
    }

    /// Vertical: cluster into columns by horizontal center, columns RIGHT→LEFT,
    /// within a column top→bottom.
    private static func vertical(_ boxes: [(text: String, box: CGRect)]) -> String {
        let tol = median(boxes.map { $0.box.width }) * 0.5
        var cols: [[(text: String, box: CGRect)]] = []
        for item in boxes.sorted(by: { $0.box.midX > $1.box.midX }) {
            if let i = cols.firstIndex(where: { abs($0[0].box.midX - item.box.midX) < tol }) {
                cols[i].append(item)
            } else {
                cols.append([item])
            }
        }
        return cols
            .sorted { rowCenter($0, \.box.midX) > rowCenter($1, \.box.midX) }   // right → left
            .map { $0.sorted { $0.box.midY > $1.box.midY }.map(\.text).joined() }
            .joined(separator: "\n")
    }

    /// Mean of a coordinate across a cluster, used as its stable representative.
    private static func rowCenter(_ cluster: [(text: String, box: CGRect)],
                                  _ key: KeyPath<(text: String, box: CGRect), CGFloat>) -> CGFloat {
        cluster.reduce(0) { $0 + $1[keyPath: key] } / CGFloat(cluster.count)
    }

    private static func median(_ xs: [CGFloat]) -> CGFloat {
        let sorted = xs.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}
