import SwiftUI
import CoreText
import ReaderCore

/// The reading surface. UILabel/UITextView can render ruby but give no per-token
/// geometry and can't do vertical text, so this is a custom CoreText draw:
///  • furigana via `CTRubyAnnotation` (`.before` auto-rotates to the column's
///    right in vertical text — no change needed between orientations),
///  • tategaki via a frame with `kCTFrameProgressionAttributeName` = `rightToLeft`
///    + `kCTVerticalFormsAttributeName` on the string,
///  • the synced highlight drawn as a rounded fill behind the active token, whose
///    text is recolored to `hiInk`,
///  • taps hit-tested against the same per-token rects → token index.
///
/// The drawer (`RubyContentView`) is sized to the WHOLE chapter and hosted in a
/// `RubyScrollView` so long texts scroll — vertically for yokogaki, horizontally
/// (right-to-left) for tategaki — and the playing highlight is kept in view.
struct RubyTextView: UIViewRepresentable {
    let spans: [TokenSpan]
    /// Increments only when `spans` is replaced. Lets the view decide whether to
    /// relayout with a single integer compare, instead of hashing every token's
    /// strings on each highlight frame.
    let structureVersion: Int
    let activeIndex: Int?
    let vertical: Bool
    let theme: Theme
    /// Reading typeface (PostScript name) + size multiplier, from Settings.
    let fontName: String
    let fontScale: CGFloat
    /// Furigana on/off, from Settings.
    let showFurigana: Bool
    var onTapToken: (Int) -> Void
    var onTapBackground: () -> Void

    func makeUIView(context: Context) -> RubyScrollView {
        let sv = RubyScrollView()
        sv.content.onTapToken = onTapToken
        sv.content.onTapBackground = onTapBackground
        return sv
    }

    func updateUIView(_ sv: RubyScrollView, context: Context) {
        sv.content.onTapToken = onTapToken
        sv.content.onTapBackground = onTapBackground
        sv.configure(spans: spans, structureVersion: structureVersion,
                     activeIndex: activeIndex, vertical: vertical,
                     fontName: fontName, fontScale: fontScale, showFurigana: showFurigana,
                     ink: theme.ink.ui, hi: theme.hi.ui, hiInk: theme.hiInk.ui)
    }
}

/// Scrolls the full-chapter CoreText drawer and follows the active token. Sizes
/// the content to the whole text on the cross-axis it can't scroll (width for
/// yokogaki, height for tategaki) and lets it grow along the other.
final class RubyScrollView: UIScrollView {
    let content = RubyContentView()

    private var vertical = true
    /// Recompute content size + reset the start offset on the next layout pass.
    private var needsResize = true
    private var didPlaceInitialOffset = false
    private var lastCrossAxis: CGFloat = -1

    /// Cross-axis reading margin INSIDE the scroll view: keeps the text column off
    /// the screen sides and clear of the scroll indicator, which rides the scroll
    /// view's outer edge (full-bleed) rather than the text edge.
    private let readingInset: CGFloat = 30
    /// Tategaki main-axis end margin: keeps the first (right) / last (left) column
    /// off the screen corner, since horizontal is the scroll axis there.
    private let columnEndInset: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = true
        // The reader provides its own top/bottom chrome insets; don't let the system
        // add safe-area insets on top.
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false       // taps reach a token without a press delay
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(spans: [TokenSpan], structureVersion: Int, activeIndex: Int?, vertical: Bool,
                   fontName: String, fontScale: CGFloat, showFurigana: Bool,
                   ink: UIColor, hi: UIColor, hiInk: UIColor) {
        let orientationChanged = (self.vertical != vertical)
        self.vertical = vertical
        let structureChanged = content.configure(
            spans: spans, structureVersion: structureVersion, activeIndex: activeIndex,
            vertical: vertical, fontName: fontName, fontScale: fontScale, showFurigana: showFurigana,
            ink: ink, hi: hi, hiInk: hiInk)

        if structureChanged || orientationChanged {
            needsResize = true
            didPlaceInitialOffset = false
            setNeedsLayout()
        } else {
            // Only the active token (or colors) changed — keep the reader's place and
            // just follow the moving highlight.
            followActive(animated: true)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }

        // The text lays out within the cross-axis minus the reading margin on both
        // sides; the scroll view itself spans full-bleed so its indicator sits at
        // the screen edge, outside the column.
        let cross = (vertical ? bounds.height : bounds.width) - readingInset * 2
        if needsResize || cross != lastCrossAxis {
            lastCrossAxis = cross
            needsResize = false
            let text = content.fittingSize(crossAxis: cross)
            if vertical {
                // Tategaki: scroll horizontally, reading right-to-left. Right-align the
                // columns (margin `columnEndInset` from the right edge) so a SHORT text
                // sits at the right — where reading starts — instead of the left; a long
                // text overflows leftward and scrolls. Column band inset top/bottom.
                let columns = text.width
                let contentW = max(bounds.width, columns + columnEndInset * 2)
                content.frame = CGRect(x: contentW - columnEndInset - columns, y: readingInset,
                                       width: columns, height: cross)
                contentSize = CGSize(width: contentW, height: bounds.height)
            } else {
                // Yokogaki: scroll vertically; inset the column left/right.
                content.frame = CGRect(x: readingInset, y: 0, width: cross, height: text.height)
                contentSize = CGSize(width: bounds.width, height: text.height)
            }
            content.setNeedsDisplay()
        }

        if !didPlaceInitialOffset {
            didPlaceInitialOffset = true
            // Tategaki reads right-to-left: start at the right edge.
            contentOffset = vertical
                ? CGPoint(x: max(0, contentSize.width - bounds.width), y: 0)
                : .zero
            followActive(animated: false)   // jump to a resumed position, if any
        }
    }

    /// Bring the active token into a comfortable reading band when it drifts out —
    /// a line-at-a-time follow during playback that doesn't fight a manual drag.
    private func followActive(animated: Bool) {
        guard !isTracking, !isDragging, !isDecelerating,
              bounds.width > 1, bounds.height > 1,
              let r0 = content.activeViewRect() else { return }
        // activeViewRect is in the content view's own coords; the content view is
        // inset within the scroll view, so shift it into scroll-content space.
        let r = r0.offsetBy(dx: content.frame.origin.x, dy: content.frame.origin.y)
        let visible = CGRect(origin: contentOffset, size: bounds.size)
        if vertical {
            let margin = bounds.width * 0.22
            guard r.minX < visible.minX + margin || r.maxX > visible.maxX else { return }
            let target = r.maxX - bounds.width * 0.75      // ~quarter in from the right
            let x = min(max(0, target), max(0, contentSize.width - bounds.width))
            setContentOffset(CGPoint(x: x, y: 0), animated: animated)
        } else {
            let margin = bounds.height * 0.22
            guard r.minY < visible.minY + margin || r.maxY > visible.maxY - margin else { return }
            let target = r.minY - bounds.height * 0.28     // ~quarter down from the top
            let y = min(max(0, target), max(0, contentSize.height - bounds.height))
            setContentOffset(CGPoint(x: 0, y: y), animated: animated)
        }
    }
}

/// A `CATiledLayer` that never fades tiles in — the reading surface should not
/// flicker as tiles rasterize during a scroll.
private final class NoFadeTiledLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0 }
}

/// The CoreText-drawing view. Its content is the WHOLE chapter, but it draws on a
/// `CATiledLayer` so only the visible tiles are ever rasterized — a full novel as
/// one chapter would otherwise need a single multi-gigabyte backing store (past
/// the GPU texture limit) and jetsam/blank out. The moving highlight lives on a
/// separate `CAShapeLayer` so advancing the active token repaints a small vector
/// path, never the chapter-sized tiled content.
final class RubyContentView: UIView {
    var onTapToken: (Int) -> Void = { _ in }
    var onTapBackground: () -> Void = {}

    /// Draw the whole chapter on a tiled layer (bounded backing store).
    override class var layerClass: AnyClass { NoFadeTiledLayer.self }

    private var spans: [TokenSpan] = []
    private var activeIndex: Int?
    private var vertical = true
    private var fontName: String = Mincho.psName        // reading typeface (Settings)
    private var fontScale: CGFloat = 1                   // size multiplier (Settings)
    private var inkColor: UIColor = .label             // applied via context fill
    private var hiColor: UIColor = .systemYellow       // active-token highlight fill

    private var attributed = NSAttributedString()
    private var tokenRanges: [NSRange] = []
    private var framesetter: CTFramesetter?
    private var ctFrame: CTFrame?
    private var frameSize: CGSize = .zero
    /// Cached line geometry for the current `ctFrame`, so tap hit-testing and the
    /// highlight don't re-fetch all line origins on every query.
    private var lines: [CTLine] = []
    private var lineOrigins: [CGPoint] = []            // flipped CoreText space
    private var lineRanges: [NSRange] = []             // each line's character range
    private var structureKey = 0
    private var showFurigana = true

    /// The active-token highlight, drawn as a vector fill above the tiled text so it
    /// can advance ~60×/sec without invalidating the chapter-sized tiles.
    private let highlightLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        if let tiled = layer as? CATiledLayer {
            tiled.levelsOfDetail = 1
            tiled.levelsOfDetailBias = 0
            let s = UIScreen.main.scale
            tiled.tileSize = CGSize(width: 512 * s, height: 512 * s)
        }
        highlightLayer.actions = ["path": NSNull()]     // no implicit animation on advance
        layer.addSublayer(highlightLayer)
        // VoiceOver reads the page as one static-text element (the reading
        // material itself). The per-token tap-to-define is a sighted affordance.
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The page reads as static text under VoiceOver; the per-token tap-to-define
    /// is a sighted-only affordance. Suppress activation so a double-tap doesn't
    /// open the definition of whatever token happens to sit at the center.
    override func accessibilityActivate() -> Bool { false }

    private var fontSize: CGFloat { (vertical ? 26 : 22) * fontScale }

    /// The reading font at the given size, falling back to the system font if the
    /// chosen face is unavailable.
    private func readingFont(_ size: CGFloat) -> UIFont {
        UIFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
    }

    // MARK: - Configure

    /// Apply new state; returns whether the token list / orientation / font changed
    /// (i.e. the host must recompute the scrollable content size).
    @discardableResult
    func configure(spans: [TokenSpan], structureVersion: Int, activeIndex: Int?, vertical: Bool,
                   fontName: String, fontScale: CGFloat, showFurigana: Bool,
                   ink: UIColor, hi: UIColor, hiInk: UIColor) -> Bool {
        // Ink recolor (theme switch) needs a full tiled repaint; the highlight fill
        // color is applied to the vector layer without touching the text tiles.
        let inkChanged = (inkColor != ink)
        inkColor = ink; hiColor = hi

        // Only a new token list (structureVersion), orientation, furigana on/off, or
        // the reading font/size affect layout. The version is a cheap O(1) proxy for
        // "spans changed", so this comparison runs every highlight frame without
        // touching the token strings.
        let key = Self.structureHash(version: structureVersion, vertical: vertical,
                                     showFurigana: showFurigana, fontName: fontName, fontScale: fontScale)
        var structureChanged = false
        if key != structureKey {
            structureKey = key
            self.spans = spans
            self.vertical = vertical
            self.showFurigana = showFurigana
            self.fontName = fontName
            self.fontScale = fontScale
            rebuild()
            structureChanged = true
        }
        self.activeIndex = activeIndex
        // Repaint the chapter-sized tiles ONLY when the text or its ink color changed —
        // never on a bare highlight advance (that just moves the vector highlight).
        if structureChanged || inkChanged { setNeedsDisplay() }
        updateHighlight()
        return structureChanged
    }

    private static func structureHash(version: Int, vertical: Bool, showFurigana: Bool,
                                      fontName: String, fontScale: CGFloat) -> Int {
        var h = Hasher()
        h.combine(version)
        h.combine(vertical)
        h.combine(showFurigana)
        h.combine(fontName)
        h.combine(fontScale)
        return h.finalize()
    }

    // MARK: - Build the attributed string + framesetter

    private func rebuild() {
        // Base runs (and ruby) take their color from the graphics context's fill
        // color at draw time (so the active token can be repainted in hiInk without
        // rebuilding the string). See the ruby annotation note below.
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let font = readingFont(fontSize)
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, fromContext: true]

        let out = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for span in spans {
            let start = out.length
            // In tategaki, half-width ASCII digits have Unicode Vertical_Orientation
            // = Rotated (CoreText lays them on their side). Swap to full-width twins,
            // which are Upright, so digits stack straight down the column. Display-only
            // and 1:1 per scalar, so `tokenRanges` stay aligned with `span.surface`.
            let display = vertical ? Self.uprightDigits(span.surface) : span.surface
            let piece = NSMutableAttributedString(string: display, attributes: baseAttrs)
            if showFurigana, let reading = span.reading, !reading.isEmpty, Self.containsKanji(span.surface) {
                let rubyFont = readingFont(fontSize * 0.5)
                // No explicit ruby color: furigana draws via the context fill (like the
                // base runs) so it inherits `ink` / `hiInk` with the text. An explicit
                // color here persists in the context mid-CTFrameDraw and bleeds onto the
                // following from-context base runs — the "first word inked, rest grayed" bug.
                let ann = CTRubyAnnotationCreateWithAttributes(
                    .center, .auto, .before, reading as CFString,
                    [kCTFontAttributeName: rubyFont] as CFDictionary)
                piece.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                                   value: ann, range: NSRange(location: 0, length: piece.length))
            }
            out.append(piece)
            ranges.append(NSRange(location: start, length: piece.length))
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = vertical ? 1.0 : 1.2
        let whole = NSRange(location: 0, length: out.length)
        out.addAttributes([.paragraphStyle: para,
                           .kern: fontSize * (vertical ? 0.04 : 0.02)], range: whole)
        if vertical {
            out.addAttribute(NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
                             value: true, range: whole)
        }

        attributed = out
        tokenRanges = ranges
        framesetter = CTFramesetterCreateWithAttributedString(out)
        ctFrame = nil
        frameSize = .zero

        // The spoken page = the concatenated surfaces (the displayed text).
        accessibilityLabel = spans.map(\.surface).joined()
    }

    // MARK: - Content sizing

    /// Size needed to lay out the whole chapter given the fixed cross-axis (width
    /// for yokogaki, height for tategaki). `CTFramesetterSuggestFrameSizeWithConstraints`
    /// only measures horizontal layout, so vertical text swaps the axes: constrain
    /// by the available column height and read back the stacked extent as the width.
    func fittingSize(crossAxis: CGFloat) -> CGSize {
        guard let framesetter, crossAxis > 1 else { return .zero }
        let suggest = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: crossAxis, height: .greatestFiniteMagnitude), nil)
        // Slack for ruby overhang / rounding so the final line/column isn't clipped.
        let main = ceil(suggest.height) + fontSize
        return vertical ? CGSize(width: main, height: crossAxis)
                        : CGSize(width: crossAxis, height: main)
    }

    // MARK: - Frame caching

    /// The laid-out CTFrame, rebuilt only when the framesetter or bounds change —
    /// NOT on every redraw (the highlight advances ~60×/sec; line-breaking must
    /// not run each frame).
    private func currentFrame() -> CTFrame? {
        guard let framesetter, bounds.width > 1, bounds.height > 1 else { return nil }
        if let f = ctFrame, frameSize == bounds.size { return f }
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: bounds.size))
        let frameAttrs: CFDictionary? = vertical
            ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
            : nil
        let f = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, frameAttrs)
        ctFrame = f
        frameSize = bounds.size
        // Cache line geometry once per layout so tap hit-testing and the highlight
        // don't re-fetch all origins on every query (they run on the hot path).
        lines = (CTFrameGetLines(f) as? [CTLine]) ?? []
        lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty { CTFrameGetLineOrigins(f, CFRangeMake(0, 0), &lineOrigins) }
        lineRanges = lines.map { let r = CTLineGetStringRange($0); return NSRange(location: r.location, length: r.length) }
        return f
    }

    /// The line indices a token's character range spans (usually 1, at most a wrap of
    /// 2). Binary-searches the sorted, contiguous `lineRanges` so token geometry is
    /// O(1) instead of scanning every line — the difference between a smooth tap and
    /// a second-long freeze on a long chapter.
    private func linesForToken(_ range: NSRange) -> Range<Int> {
        guard !lineRanges.isEmpty else { return 0..<0 }
        let tEnd = range.location + range.length
        // First line whose end is past the token start.
        var lo = 0, hi = lineRanges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lineRanges[mid].location + lineRanges[mid].length <= range.location { lo = mid + 1 } else { hi = mid }
        }
        let first = lo
        var last = first
        while last < lineRanges.count && lineRanges[last].location < tEnd { last += 1 }
        return first..<max(first, last)
    }

    // MARK: - Draw

    override func layoutSubviews() {
        super.layoutSubviews()
        highlightLayer.frame = bounds
        // Build the frame on the MAIN thread here so the background tile draws only
        // read the (immutable) CTFrame — never race to build it.
        _ = currentFrame()
        setNeedsDisplay()
        updateHighlight()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let frame = ctFrame else { return }
        // CATiledLayer calls this once per tile (`rect` = the tile) with the context
        // already clipped/translated to that tile, possibly off the main thread. We
        // draw the whole frame flipped into UIKit space; CoreText clips to the tile, so
        // only visible tiles rasterize and the backing store stays bounded. Ruby
        // annotations render exactly as before — CTFrameDraw is unchanged by tiling.
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(inkColor.cgColor)
        CTFrameDraw(frame, ctx)
    }

    /// Reposition the active-token highlight (vector, above the tiled text). Cheap
    /// enough to run every audio frame — no tile invalidation.
    private func updateHighlight() {
        highlightLayer.fillColor = hiColor.cgColor
        guard ctFrame != nil, let active = activeIndex,
              active >= 0, active < tokenRanges.count else {
            highlightLayer.path = nil
            return
        }
        let rects = tokenRects(tokenRanges[active])   // flipped CoreText space
        guard !rects.isEmpty else { highlightLayer.path = nil; return }
        let path = CGMutablePath()
        for r in rects {
            // Flip each rect into the layer's top-left space, then round it.
            let tl = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
            path.addRoundedRect(in: tl.insetBy(dx: -4, dy: -3), cornerWidth: 6, cornerHeight: 6)
        }
        highlightLayer.path = path
    }

    // MARK: - Token geometry (in flipped CoreText space)

    private func tokenRects(_ range: NSRange) -> [CGRect] {
        guard !lines.isEmpty else { return [] }
        var rects: [CGRect] = []
        let tStart = range.location, tEnd = range.location + range.length
        for i in linesForToken(range) {
            let line = lines[i]
            let lr = lineRanges[i]
            let s = max(lr.location, tStart)
            let e = min(lr.location + lr.length, tEnd)
            guard s < e else { continue }

            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let off1 = CTLineGetOffsetForStringIndex(line, s, nil)
            let off2 = CTLineGetOffsetForStringIndex(line, e, nil)
            let origin = lineOrigins[i]

            if vertical {
                let yTop = origin.y - min(off1, off2)
                let yBot = origin.y - max(off1, off2)
                rects.append(CGRect(x: origin.x - descent, y: min(yTop, yBot),
                                    width: ascent + descent, height: abs(off2 - off1)))
            } else {
                rects.append(CGRect(x: min(off1, off2), y: origin.y - descent,
                                    width: abs(off2 - off1), height: ascent + descent))
            }
        }
        return rects
    }

    /// The active token's bounding box in this view's (top-left) coordinate space,
    /// for the scroll-to-follow. `nil` when there's no active token or no frame yet.
    func activeViewRect() -> CGRect? {
        guard let active = activeIndex, active >= 0, active < tokenRanges.count,
              currentFrame() != nil else { return nil }
        let rects = tokenRects(tokenRanges[active])
        guard let first = rects.first else { return nil }
        let union = rects.dropFirst().reduce(first) { $0.union($1) }
        // tokenRects are in flipped CoreText space (y from the bottom); flip to view.
        return CGRect(x: union.minX, y: bounds.height - union.maxY,
                      width: union.width, height: union.height)
    }

    // MARK: - Tap

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard currentFrame() != nil else { onTapBackground(); return }
        let p = g.location(in: self)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)   // into CoreText space
        // Find the line the tap fell on (its char range), then test only the tokens on
        // that line — each token's geometry is now O(1) via `linesForToken`. Avoids the
        // old O(tokens × lines) scan that froze on long chapters.
        guard let li = lineIndex(at: flipped) else { onTapBackground(); return }
        let lr = lineRanges[li]
        for (idx, range) in tokenRanges.enumerated() {
            guard range.location < lr.location + lr.length, range.location + range.length > lr.location else {
                if range.location >= lr.location + lr.length { break }   // past this line; ranges are sorted
                continue
            }
            for r in tokenRects(range) where r.insetBy(dx: -4, dy: -4).contains(flipped) {
                onTapToken(idx)
                return
            }
        }
        onTapBackground()
    }

    /// The index of the line whose typographic band contains `flipped` (CoreText
    /// space), or nil if the tap missed every line.
    private func lineIndex(at flipped: CGPoint) -> Int? {
        for (i, line) in lines.enumerated() {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let o = lineOrigins[i]
            let band = vertical
                ? (flipped.x >= o.x - descent && flipped.x <= o.x + ascent)
                : (flipped.y >= o.y - descent && flipped.y <= o.y + ascent)
            if band { return i }
        }
        return nil
    }

    /// Map half-width ASCII digits (0-9) to their full-width twins (U+FF10–FF19)
    /// for upright stacking in vertical text. A 1:1 scalar swap (both single UTF-16
    /// units), so it never shifts the offsets `tokenRanges` indexes into.
    private static func uprightDigits(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0x30...0x39).contains($0.value) }) else { return s }
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            if (0x30...0x39).contains(scalar.value) {
                out.append(Unicode.Scalar(scalar.value - 0x30 + 0xFF10)!)
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    private static func containsKanji(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
}
