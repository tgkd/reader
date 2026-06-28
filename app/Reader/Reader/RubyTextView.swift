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
struct RubyTextView: UIViewRepresentable {
    let spans: [TokenSpan]
    /// Increments only when `spans` is replaced. Lets the view decide whether to
    /// relayout with a single integer compare, instead of hashing every token's
    /// strings on each highlight frame.
    let structureVersion: Int
    let activeIndex: Int?
    let vertical: Bool
    let theme: Theme
    var onTapToken: (Int) -> Void
    var onTapBackground: () -> Void

    func makeUIView(context: Context) -> RubyUIView {
        let v = RubyUIView()
        v.onTapToken = onTapToken
        v.onTapBackground = onTapBackground
        return v
    }

    func updateUIView(_ v: RubyUIView, context: Context) {
        v.onTapToken = onTapToken
        v.onTapBackground = onTapBackground
        v.configure(spans: spans, structureVersion: structureVersion,
                    activeIndex: activeIndex, vertical: vertical,
                    ink: theme.ink.ui, ruby: theme.muted.ui, hi: theme.hi.ui, hiInk: theme.hiInk.ui)
    }
}

/// The CoreText-drawing UIView behind `RubyTextView`.
final class RubyUIView: UIView {
    var onTapToken: (Int) -> Void = { _ in }
    var onTapBackground: () -> Void = {}

    private var spans: [TokenSpan] = []
    private var activeIndex: Int?
    private var vertical = true
    private var rubyColor: UIColor = .secondaryLabel   // baked into the string
    private var inkColor: UIColor = .label             // applied via context fill
    private var hiColor: UIColor = .systemYellow       // draw-time
    private var hiInkColor: UIColor = .label           // draw-time

    private var attributed = NSAttributedString()
    private var tokenRanges: [NSRange] = []
    private var framesetter: CTFramesetter?
    private var ctFrame: CTFrame?
    private var frameSize: CGSize = .zero
    private var structureKey = 0
    private let showFurigana = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
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

    private var fontSize: CGFloat { vertical ? 26 : 22 }

    // MARK: - Configure

    func configure(spans: [TokenSpan], structureVersion: Int, activeIndex: Int?, vertical: Bool,
                   ink: UIColor, ruby: UIColor, hi: UIColor, hiInk: UIColor) {
        // Draw-time colors: changing them only needs a redraw, never a relayout.
        inkColor = ink; hiColor = hi; hiInkColor = hiInk

        // Only a new token list (structureVersion), orientation, or ruby color
        // affect layout. The version is a cheap O(1) proxy for "spans changed",
        // so this comparison runs every highlight frame without touching the
        // token strings.
        let key = Self.structureHash(version: structureVersion, vertical: vertical, ruby: ruby)
        if key != structureKey {
            structureKey = key
            self.spans = spans
            self.vertical = vertical
            self.rubyColor = ruby
            rebuild()
        }
        self.activeIndex = activeIndex
        setNeedsDisplay()
    }

    private static func structureHash(version: Int, vertical: Bool, ruby: UIColor) -> Int {
        var h = Hasher()
        h.combine(version)
        h.combine(vertical)
        h.combine(ruby)
        return h.finalize()
    }

    // MARK: - Build the attributed string + framesetter

    private func rebuild() {
        // Base runs take their color from the graphics context's fill color at
        // draw time (so the active token can be repainted in hiInk without
        // rebuilding the string); ruby keeps an explicit color.
        let fromContext = NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String)
        let font = Mincho.uiFont(fontSize)
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, fromContext: true]

        let out = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for span in spans {
            let start = out.length
            let piece = NSMutableAttributedString(string: span.surface, attributes: baseAttrs)
            if showFurigana, let reading = span.reading, !reading.isEmpty, Self.containsKanji(span.surface) {
                let rubyFont = Mincho.uiFont(fontSize * 0.5)
                let ann = CTRubyAnnotationCreateWithAttributes(
                    .center, .auto, .before, reading as CFString,
                    [kCTFontAttributeName: rubyFont,
                     kCTForegroundColorAttributeName: rubyColor.cgColor] as CFDictionary)
                piece.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                                   value: ann, range: NSRange(location: 0, length: piece.length))
            }
            out.append(piece)
            ranges.append(NSRange(location: start, length: piece.length))
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineHeightMultiple = vertical ? 1.0 : 1.55
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
        return f
    }

    // MARK: - Draw

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), let frame = currentFrame() else { return }

        // CoreText draws in a bottom-left origin; flip into UIKit space.
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)

        var activeRects: [CGRect] = []
        if let active = activeIndex, active >= 0, active < tokenRanges.count {
            activeRects = tokenRects(tokenRanges[active], frame: frame)
            ctx.setFillColor(hiColor.cgColor)
            for r in activeRects {
                ctx.addPath(CGPath(roundedRect: r.insetBy(dx: -4, dy: -3),
                                   cornerWidth: 6, cornerHeight: 6, transform: nil))
                ctx.fillPath()
            }
        }

        // Base text in ink (context fill colors the from-context runs).
        ctx.setFillColor(inkColor.cgColor)
        CTFrameDraw(frame, ctx)

        // Repaint the active token's text in hiInk, clipped to its rects.
        if !activeRects.isEmpty {
            ctx.saveGState()
            for r in activeRects { ctx.addRect(r.insetBy(dx: -4, dy: -3)) }
            ctx.clip()
            ctx.setFillColor(hiInkColor.cgColor)
            CTFrameDraw(frame, ctx)
            ctx.restoreGState()
        }
    }

    // MARK: - Token geometry (in flipped CoreText space)

    private func tokenRects(_ range: NSRange, frame: CTFrame) -> [CGRect] {
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), &origins)

        var rects: [CGRect] = []
        let tStart = range.location, tEnd = range.location + range.length
        for (i, line) in lines.enumerated() {
            let lr = CTLineGetStringRange(line)
            let s = max(lr.location, tStart)
            let e = min(lr.location + lr.length, tEnd)
            guard s < e else { continue }

            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
            let off1 = CTLineGetOffsetForStringIndex(line, s, nil)
            let off2 = CTLineGetOffsetForStringIndex(line, e, nil)
            let origin = origins[i]

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

    // MARK: - Tap

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard let frame = currentFrame() else { onTapBackground(); return }
        let p = g.location(in: self)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)   // into CoreText space
        for (idx, range) in tokenRanges.enumerated() {
            for r in tokenRects(range, frame: frame) where r.insetBy(dx: -4, dy: -4).contains(flipped) {
                onTapToken(idx)
                return
            }
        }
        onTapBackground()
    }

    private static func containsKanji(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }
}
