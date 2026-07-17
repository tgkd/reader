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
    /// Clearance for the floating glass chrome. Applied INSIDE the scroll view
    /// (content inset / column band), so text starts clear of the pills but
    /// scrolls under them.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var onTapToken: (Int) -> Void
    var onTapBackground: () -> Void
    /// End-of-chapter affordance: non-nil shows a "next chapter" capsule past the
    /// last line; nil (last chapter / single-chapter book) hides it.
    var onNextChapter: (() -> Void)? = nil

    func makeUIView(context: Context) -> RubyScrollView {
        let sv = RubyScrollView()
        sv.content.onTapToken = onTapToken
        sv.content.onTapBackground = onTapBackground
        return sv
    }

    func updateUIView(_ sv: RubyScrollView, context: Context) {
        sv.content.onTapToken = onTapToken
        sv.content.onTapBackground = onTapBackground
        sv.onNextChapter = onNextChapter
        sv.configure(spans: spans, structureVersion: structureVersion,
                     activeIndex: activeIndex, vertical: vertical,
                     fontName: fontName, fontScale: fontScale, showFurigana: showFurigana,
                     topInset: topInset, bottomInset: bottomInset,
                     ink: theme.ink.ui, hi: theme.hi.ui, hiInk: theme.hiInk.ui)
    }
}

/// Scrolls the full-chapter CoreText drawer and follows the active token. Sizes
/// the content to the whole text on the cross-axis it can't scroll (width for
/// yokogaki, height for tategaki) and lets it grow along the other.
final class RubyScrollView: UIScrollView {
    let content = RubyContentView()

    /// Opens the next chapter from the end-of-content capsule. Setting/clearing
    /// toggles the button and reclaims its band on the next layout pass. The
    /// button lives INSIDE the scroll content — past the last line in yokogaki,
    /// past the last (leftmost) column in tategaki — so it appears exactly where
    /// reading ends in either mode, not floating over the text.
    var onNextChapter: (() -> Void)? {
        didSet {
            let shows = onNextChapter != nil
            guard nextButton.isHidden == shows else { return }
            nextButton.isHidden = !shows
            needsResize = true
            setNeedsLayout()
        }
    }

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
    /// Main-axis room reserved after the content for the next-chapter capsule.
    private let nextBand: CGFloat = 96

    private lazy var nextButton: UIButton = {
        var config = UIButton.Configuration.glass()
        config.title = L10n.readerNextChapter
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        let b = UIButton(configuration: config)
        b.addTarget(self, action: #selector(nextChapterTapped), for: .touchUpInside)
        b.isHidden = true
        return b
    }()
    /// Last ink applied to the capsule label, so the per-frame `configure` only
    /// touches `UIButton.Configuration` on an actual theme change.
    private var nextButtonInk: UIColor?

    @objc private func nextChapterTapped() { onNextChapter?() }
    /// Clearance for the floating glass chrome. Yokogaki applies it as a vertical
    /// `contentInset` (text starts below the header pill but SCROLLS under it —
    /// the glass gets something to blur); tategaki, whose columns span the full
    /// height, uses it as the column band instead so text isn't permanently
    /// hidden under the pills.
    private var chromeTop: CGFloat = 0
    private var chromeBottom: CGFloat = 0

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
        addSubview(nextButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(spans: [TokenSpan], structureVersion: Int, activeIndex: Int?, vertical: Bool,
                   fontName: String, fontScale: CGFloat, showFurigana: Bool,
                   topInset: CGFloat, bottomInset: CGFloat,
                   ink: UIColor, hi: UIColor, hiInk: UIColor) {
        let orientationChanged = (self.vertical != vertical)
        self.vertical = vertical
        // Always draggable along the reading axis (cross axis stays locked), so a
        // short chapter can still be pulled out from under the floating chrome.
        alwaysBounceVertical = !vertical
        alwaysBounceHorizontal = vertical
        let insetsChanged = (chromeTop != topInset || chromeBottom != bottomInset)
        chromeTop = topInset
        chromeBottom = bottomInset
        let structureChanged = content.configure(
            spans: spans, structureVersion: structureVersion, activeIndex: activeIndex,
            vertical: vertical, fontName: fontName, fontScale: fontScale, showFurigana: showFurigana,
            ink: ink, hi: hi, hiInk: hiInk)
        if nextButtonInk == nil || !RubyContentView.sameColor(nextButtonInk!, ink) {
            nextButtonInk = ink
            nextButton.configuration?.baseForegroundColor = ink
        }

        if structureChanged || orientationChanged || insetsChanged {
            stopFollowing()   // the old geometry's target is garbage until relayout
            needsResize = true
            didPlaceInitialOffset = false
            setNeedsLayout()
        } else {
            // Only the active token (or colors) changed — keep the reader's place and
            // ease the moving highlight's line back to screen center.
            ensureFollowing()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }

        // The text lays out within the cross-axis minus the margins: side reading
        // margin for yokogaki, the chrome band for tategaki (whose columns span
        // the full height and must stay between the floating pills).
        let cross = vertical
            ? bounds.height - chromeTop - chromeBottom
            : bounds.width - readingInset * 2
        if needsResize || cross != lastCrossAxis {
            lastCrossAxis = cross
            needsResize = false
            let text = content.fittingSize(crossAxis: cross)
            // The next-chapter capsule extends the content along the reading axis.
            let band = nextButton.isHidden ? 0 : nextBand
            if vertical {
                // Tategaki: scroll horizontally, reading right-to-left. Right-align the
                // columns (margin `columnEndInset` from the right edge) so a SHORT text
                // sits at the right — where reading starts — instead of the left; a long
                // text overflows leftward and scrolls. Column band = chrome clearance.
                let columns = text.width
                let contentW = max(bounds.width, columns + columnEndInset * 2 + band)
                content.frame = CGRect(x: contentW - columnEndInset - columns, y: chromeTop,
                                       width: columns, height: cross)
                contentSize = CGSize(width: contentW, height: bounds.height)
                contentInset = .zero
            } else {
                // Yokogaki: scroll vertically; inset the column left/right. The chrome
                // clearance is a CONTENT inset so text scrolls under the glass pills.
                content.frame = CGRect(x: readingInset, y: 0, width: cross, height: text.height)
                contentSize = CGSize(width: bounds.width, height: text.height + band)
                contentInset = UIEdgeInsets(top: chromeTop, left: 0, bottom: chromeBottom, right: 0)
            }
            if !nextButton.isHidden {
                nextButton.sizeToFit()
                nextButton.center = vertical
                    ? CGPoint(x: content.frame.minX - band / 2, y: chromeTop + cross / 2)
                    : CGPoint(x: bounds.width / 2, y: content.frame.maxY + band / 2)
            }
            content.setNeedsDisplay()
        }

        if !didPlaceInitialOffset {
            didPlaceInitialOffset = true
            // Tategaki reads right-to-left: start at the right edge; yokogaki
            // starts at the top of the inset range (below the header pill).
            contentOffset = vertical
                ? CGPoint(x: max(0, contentSize.width - bounds.width), y: 0)
                : CGPoint(x: 0, y: -adjustedContentInset.top)
            jumpToActive()   // snap a resumed position to center, no fly-in
        }
    }

    // MARK: - Smooth centered follow

    /// Keeps the active line at screen center while the highlight advances —
    /// clamped to the scrollable range, so chapter start/end pin naturally. A
    /// critically-damped display-link ease writes `contentOffset` directly, never
    /// `setContentOffset(animated:)` (UIKit's own offset animation retriggered on
    /// every line change is a lurch, not a glide). Scrolling only moves layers, so
    /// the CoreText base is never repainted; the link lives only while the view is
    /// out of position, never at idle.
    private var followLink: CADisplayLink?
    private var settledFrames = 0

    /// The centered offset for the active line, clamped to the scrollable range
    /// (content insets included, so chapter start/end pin just clear of the pills).
    private func targetOffset() -> CGFloat? {
        guard let center = content.activeLineCenter() else { return nil }
        if vertical {
            let t = center + content.frame.origin.x - bounds.width / 2
            let lo = -adjustedContentInset.left
            let hi = max(lo, contentSize.width - bounds.width + adjustedContentInset.right)
            return min(max(lo, t), hi)
        }
        let t = center + content.frame.origin.y - bounds.height / 2
        let lo = -adjustedContentInset.top
        let hi = max(lo, contentSize.height - bounds.height + adjustedContentInset.bottom)
        return min(max(lo, t), hi)
    }

    /// Arm the follow link (called on every active-token advance). Already settled
    /// on target → it stops itself within a few frames.
    private func ensureFollowing() {
        guard content.activeLineCenter() != nil else { return }
        if UIAccessibility.isReduceMotionEnabled { jumpToActive(); return }
        settledFrames = 0
        guard followLink == nil else { return }
        let link = CADisplayLink(target: FollowTarget(self), selector: #selector(FollowTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        followLink = link
    }

    private func stopFollowing() {
        followLink?.invalidate()
        followLink = nil
    }

    /// One follow frame: ease the offset toward the centered target.
    fileprivate func stepFollow(_ link: CADisplayLink) {
        guard window != nil else { stopFollowing(); return }
        // A manual drag wins instantly; the follow re-engages once it ends.
        guard !isTracking, !isDragging, !isDecelerating else { return }
        guard bounds.width > 1, bounds.height > 1, let target = targetOffset() else {
            stopFollowing()
            return
        }
        let current = vertical ? contentOffset.x : contentOffset.y
        let delta = target - current
        if abs(delta) < 0.5 {
            settledFrames += 1
            if settledFrames > 30 { stopFollowing() }   // battery: never idle at 60 Hz
            return
        }
        settledFrames = 0
        // Exponential approach, ~140 ms time constant — critically damped, no overshoot.
        let dt = link.targetTimestamp - link.timestamp
        let next = current + delta * (1 - exp(-7 * dt))
        contentOffset = vertical ? CGPoint(x: next, y: 0) : CGPoint(x: 0, y: next)
    }

    /// Snap the active line to center with no animation (initial / resumed
    /// placement, and the Reduce Motion path).
    private func jumpToActive() {
        guard let target = targetOffset() else { return }
        contentOffset = vertical ? CGPoint(x: target, y: 0) : CGPoint(x: 0, y: target)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopFollowing() }   // the link must not outlive the screen
    }
}

/// Weak display-link target so the scroll view sits outside the link's retain
/// cycle (mirrors `DisplayLinkProxy` in ReaderModel). Ticks arrive on the main
/// run loop, so hopping via `assumeIsolated` is valid.
private final class FollowTarget: NSObject {
    private weak var view: RubyScrollView?
    init(_ view: RubyScrollView) { self.view = view }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            guard let view else { link.invalidate(); return }
            view.stepFollow(link)
        }
    }
}

/// The CoreText-drawing view, sized to the whole chapter and hosted in a
/// `RubyScrollView`. The base text is drawn once (rebuilt only on a structure /
/// font / theme change), and the moving highlight lives on a separate
/// `CAShapeLayer` so advancing the active token ~60×/sec repaints a small vector
/// path instead of the whole chapter — no per-frame full redraw.
final class RubyContentView: UIView {
    var onTapToken: (Int) -> Void = { _ in }
    var onTapBackground: () -> Void = {}

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

    /// The active-token highlight, drawn as a vector fill above the text so it can
    /// advance ~60×/sec without invalidating the chapter-sized base drawing.
    private let highlightLayer = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
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
        // Ink recolor (theme switch) needs a full base repaint; the highlight fill
        // color is applied to the vector layer separately. Compare resolved RGBA —
        // `UIColor !=` is unreliable for SwiftUI-bridged colors, and a missed compare
        // leaves the old theme's ink painted (black text on the night background).
        let inkChanged = !Self.sameColor(inkColor, ink)
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
            structureChanged = true
        }
        // The ink color is baked into the runs, so a theme switch must rebuild the
        // attributed string (not just repaint). Both cases relayout + repaint the base;
        // a bare highlight advance does neither (it only moves the vector layer) — that
        // is what keeps playback off the per-frame full-redraw path.
        if structureChanged || inkChanged {
            rebuild()
            setNeedsDisplay()
        }
        self.activeIndex = activeIndex
        updateHighlight()
        return structureChanged
    }

    /// Whether two colors resolve to the same RGBA (reliable across SwiftUI-bridged
    /// UIColors, unlike `==`). Fileprivate: the host scroll view uses it to gate
    /// its own theme-dependent updates on the same per-frame configure path.
    fileprivate static func sameColor(_ a: UIColor, _ b: UIColor) -> Bool {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return abs(ar - br) < 0.001 && abs(ag - bg) < 0.001 && abs(ab - bb) < 0.001 && abs(aa - ba) < 0.001
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
        // Bake an explicit ink color into every base run AND ruby annotation. Relying
        // on the context fill (kCTForegroundColorFromContext) breaks in night theme:
        // drawing the first ruby annotation clobbers the context fill, so every run
        // after it loses the light ink and renders near-black on the dark background
        // ("first word inked, rest grayed"). Explicit per-run color is immune to that.
        // The active-token emphasis is a separate CAShapeLayer fill, so no run ever
        // needs recoloring at draw time — hence no need for from-context here.
        let font = readingFont(fontSize)
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inkColor]

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
                let ann = CTRubyAnnotationCreateWithAttributes(
                    .center, .auto, .before, reading as CFString,
                    [kCTFontAttributeName: rubyFont,
                     kCTForegroundColorAttributeName: inkColor.cgColor] as CFDictionary)
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
        setNeedsDisplay()      // bounds changed → relayout the frame and repaint the base
        updateHighlight()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let frame = currentFrame() else { return }
        // CoreText draws in a bottom-left origin; flip into UIKit space, then draw the
        // whole chapter in ink. This runs only on a structure/font/theme change (see
        // configure) — never per highlight frame — so it's off the playback hot path.
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(inkColor.cgColor)
        CTFrameDraw(frame, ctx)
    }

    /// Reposition the active-token highlight (vector, above the text). Cheap enough
    /// to run every audio frame — no base repaint.
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

    /// Main-axis center of the FIRST line containing the active token, in this
    /// view's top-left coordinate space (y for yokogaki, x for tategaki).
    /// Line-based so the follow target holds still while the highlight advances
    /// within a line — no intra-line jitter. Reads the cached line geometry
    /// (O(log n) binary search); never triggers layout. `nil` when there's no
    /// active token or no frame yet.
    func activeLineCenter() -> CGFloat? {
        guard let active = activeIndex, active >= 0, active < tokenRanges.count,
              currentFrame() != nil else { return nil }
        guard let i = linesForToken(tokenRanges[active]).first, i < lines.count else { return nil }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(lines[i], &ascent, &descent, &leading)
        let origin = lineOrigins[i]   // flipped CoreText space
        if vertical {
            // The column band spans x ∈ [origin.x − descent, origin.x + ascent];
            // x doesn't flip between CoreText and view space.
            return origin.x + (ascent - descent) / 2
        }
        // The line band spans y ∈ [origin.y − descent, origin.y + ascent] (flipped).
        return bounds.height - origin.y - (ascent - descent) / 2
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
