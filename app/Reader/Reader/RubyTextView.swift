import SwiftUI
import CoreText
import ReaderCore

struct RubyTextView: UIViewRepresentable {
    let spans: [TokenSpan]
    let structureVersion: Int
    let activeIndex: Int?
    let vertical: Bool
    let chapterID: UUID?
    let theme: Theme
    let fontName: String
    let fontScale: CGFloat
    let showFurigana: Bool
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var initialToken: Int? = nil
    var onTapToken: (Int) -> Void
    var onTapBackground: () -> Void
    var onVisibleToken: ((Int) -> Void)? = nil
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
        sv.onVisibleToken = onVisibleToken
        sv.onNextChapter = onNextChapter
        sv.configure(spans: spans, structureVersion: structureVersion,
                     activeIndex: activeIndex, vertical: vertical, chapterID: chapterID,
                     initialToken: initialToken,
                     fontName: fontName, fontScale: fontScale, showFurigana: showFurigana,
                     topInset: topInset, bottomInset: bottomInset,
                     ink: theme.ink.ui, hi: theme.hi.ui)
    }
}

final class RubyScrollView: UIScrollView, UIScrollViewDelegate {
    let content = RubyContentView()

    var onVisibleToken: ((Int) -> Void)?

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
    private var needsResize = true
    private var didPlaceInitialOffset = false
    private var lastCrossAxis: CGFloat = -1
    private var chapterID: UUID?
    private var pendingAnchor: Int?
    private var lastActiveIndex: Int?
    private var userParked = false

    private let readingInset: CGFloat = 30
    private let columnEndInset: CGFloat = 24
    private let nextBand: CGFloat = 96
    private let nextButtonDiameter: CGFloat = 52

    private lazy var nextButton: UIButton = {
        var config = UIButton.Configuration.glass()
        config.image = UIImage(systemName: "arrow.forward",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        config.cornerStyle = .capsule
        let b = UIButton(configuration: config)
        b.accessibilityLabel = L10n.readerNextChapter
        b.addTarget(self, action: #selector(nextChapterTapped), for: .touchUpInside)
        b.isHidden = true
        return b
    }()
    private var nextButtonInk: UIColor?

    @objc private func nextChapterTapped() { onNextChapter?() }
    private var chromeTop: CGFloat = 0
    private var chromeBottom: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        showsVerticalScrollIndicator = true
        showsHorizontalScrollIndicator = true
        contentInsetAdjustmentBehavior = .never
        delaysContentTouches = false
        alwaysBounceVertical = false
        alwaysBounceHorizontal = false
        addSubview(content)
        addSubview(nextButton)
        content.viewportCenter = { [weak self] in self?.viewportCenterInContent() }
        delegate = self
    }

    private func reportVisibleToken() {
        guard let onVisibleToken,
              let point = viewportCenterInContent(),
              let token = content.tokenIndex(at: point) else { return }
        onVisibleToken(token)
    }

    private func pushVisibleRect() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        content.setVisibleRect(convert(bounds, to: content))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        pushVisibleRect()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userParked = true
        stopFollowing()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        reportVisibleToken()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportVisibleToken() }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { reportVisibleToken() }

    private func viewportCenterInContent() -> CGPoint? {
        guard bounds.width > 1, bounds.height > 1,
              content.bounds.width > 1, content.bounds.height > 1 else { return nil }
        return CGPoint(x: contentOffset.x + bounds.width / 2 - content.frame.origin.x,
                       y: contentOffset.y + bounds.height / 2 - content.frame.origin.y)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(spans: [TokenSpan], structureVersion: Int, activeIndex: Int?, vertical: Bool,
                   chapterID: UUID?, initialToken: Int?,
                   fontName: String, fontScale: CGFloat, showFurigana: Bool,
                   topInset: CGFloat, bottomInset: CGFloat,
                   ink: UIColor, hi: UIColor) {
        let sameChapter = (self.chapterID == chapterID)
        if !sameChapter { pendingAnchor = initialToken }
        self.chapterID = chapterID
        content.keepsPlaceAcrossReflow = sameChapter
        if !sameChapter { userParked = false }
        if activeIndex != lastActiveIndex {
            lastActiveIndex = activeIndex
            userParked = false
        }

        let orientationChanged = (self.vertical != vertical)
        self.vertical = vertical
        alwaysBounceVertical = !vertical
        alwaysBounceHorizontal = vertical
        let insetsChanged = (chromeTop != topInset || chromeBottom != bottomInset)
        let anchorBeforeInsetChange = (insetsChanged && sameChapter)
            ? viewportCenterInContent().flatMap { content.tokenIndex(at: $0) }
            : nil
        chromeTop = topInset
        chromeBottom = bottomInset
        let structureChanged = content.configure(
            spans: spans, structureVersion: structureVersion, activeIndex: activeIndex,
            vertical: vertical, fontName: fontName, fontScale: fontScale, showFurigana: showFurigana,
            ink: ink, hi: hi)
        if nextButtonInk == nil || !RubyContentView.sameColor(nextButtonInk!, ink) {
            nextButtonInk = ink
            nextButton.configuration?.baseForegroundColor = ink
        }

        if structureChanged || orientationChanged || insetsChanged {
            pendingAnchor = content.takeReflowAnchor() ?? anchorBeforeInsetChange ?? pendingAnchor
            stopFollowing()
            needsResize = true
            didPlaceInitialOffset = false
            setNeedsLayout()
        } else {
            ensureFollowing()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }

        let cross = vertical
            ? bounds.height - chromeTop - chromeBottom
            : bounds.width - readingInset * 2
        if needsResize || cross != lastCrossAxis {
            lastCrossAxis = cross
            needsResize = false
            let text = content.fittingSize(crossAxis: cross)
            if !nextButton.isHidden {
                nextButton.bounds.size = CGSize(width: nextButtonDiameter, height: nextButtonDiameter)
            }
            let band: CGFloat = nextButton.isHidden
                ? 0
                : (vertical ? nextButton.bounds.width + columnEndInset : nextBand)
            if vertical {
                let columns = text.width
                let contentW = max(bounds.width, columns + columnEndInset * 2 + band)
                content.frame = CGRect(x: contentW - columnEndInset - columns, y: chromeTop,
                                       width: columns, height: cross)
                contentSize = CGSize(width: contentW, height: bounds.height)
                contentInset = .zero
                if !nextButton.isHidden {
                    nextButton.center = CGPoint(
                        x: columnEndInset + nextButton.bounds.width / 2,
                        y: chromeTop + cross - nextButton.bounds.height / 2)
                }
            } else {
                content.frame = CGRect(x: readingInset, y: 0, width: cross, height: text.height)
                let contentH = max(text.height + band, bounds.height - chromeTop - chromeBottom)
                contentSize = CGSize(width: bounds.width, height: contentH)
                contentInset = UIEdgeInsets(top: chromeTop, left: 0, bottom: chromeBottom, right: 0)
                if !nextButton.isHidden {
                    nextButton.center = CGPoint(x: bounds.width / 2, y: contentH - band / 2)
                }
            }
            pushVisibleRect()
        }

        if !didPlaceInitialOffset {
            didPlaceInitialOffset = true
            contentOffset = vertical
                ? CGPoint(x: max(0, contentSize.width - bounds.width), y: 0)
                : CGPoint(x: 0, y: -adjustedContentInset.top)
            if !jumpToActive() { jumpToAnchor() }
            pendingAnchor = nil
        }
    }

    private var followLink: CADisplayLink?
    private var settledFrames = 0

    private func targetOffset() -> CGFloat? {
        content.activeLineCenter().map(offset(centering:))
    }

    private func offset(centering center: CGFloat) -> CGFloat {
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

    private func ensureFollowing() {
        guard !userParked, content.activeLineCenter() != nil else { return }
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

    fileprivate func stepFollow(_ link: CADisplayLink) {
        guard window != nil else { stopFollowing(); return }
        guard !isTracking, !isDragging, !isDecelerating else { return }
        guard bounds.width > 1, bounds.height > 1, let target = targetOffset() else {
            stopFollowing()
            return
        }
        let current = vertical ? contentOffset.x : contentOffset.y
        let delta = target - current
        if abs(delta) < 0.5 {
            settledFrames += 1
            if settledFrames > 30 { stopFollowing() }
            return
        }
        settledFrames = 0
        let dt = link.targetTimestamp - link.timestamp
        let next = current + delta * (1 - exp(-7 * dt))
        contentOffset = vertical ? CGPoint(x: next, y: 0) : CGPoint(x: 0, y: next)
    }

    @discardableResult
    private func jumpToActive() -> Bool {
        guard let target = targetOffset() else { return false }
        contentOffset = vertical ? CGPoint(x: target, y: 0) : CGPoint(x: 0, y: target)
        return true
    }

    private func jumpToAnchor() {
        guard let token = pendingAnchor, let center = content.lineCenter(forToken: token) else { return }
        let target = offset(centering: center)
        contentOffset = vertical ? CGPoint(x: target, y: 0) : CGPoint(x: 0, y: target)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { stopFollowing() }
    }
}

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

final class RubyContentView: UIView {
    var onTapToken: (Int) -> Void = { _ in }
    var onTapBackground: () -> Void = {}

    private var spans: [TokenSpan] = []
    private var activeIndex: Int?
    private var vertical = true
    private var fontName: String = Mincho.psName
    private var fontScale: CGFloat = 1
    private var inkColor: UIColor = .label
    private var hiColor: UIColor = .systemYellow

    private var attributed = NSAttributedString()
    private var tokenRanges: [NSRange] = []
    private var framesetter: CTFramesetter?
    private var ctFrame: CTFrame?
    private var frameSize: CGSize = .zero
    private var lines: [CTLine] = []
    private var lineOrigins: [CGPoint] = []
    private var lineRanges: [NSRange] = []
    private var structureKey = 0
    private var showFurigana = true

    var viewportCenter: (() -> CGPoint?)?
    var keepsPlaceAcrossReflow = false
    private var reflowAnchor: Int?

    private let highlightLayer = CAShapeLayer()
    private let drawLock = NSLock()

    private struct TileKey: Hashable { let col: Int; let row: Int }

    private static let tileSide: CGFloat = 512
    private let tileQueue = DispatchQueue(label: "app.reader.text-tiles", qos: .userInitiated)
    private var tileLayers: [TileKey: CALayer] = [:]
    private var tileGeneration = 0
    private var tiledSize: CGSize = .zero
    private var visibleRect: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        highlightLayer.actions = ["path": NSNull()]
        layer.addSublayer(highlightLayer)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityActivate() -> Bool { false }

    private var fontSize: CGFloat { (vertical ? 26 : 22) * fontScale }

    private func readingFont(_ size: CGFloat) -> UIFont {
        UIFont(name: fontName, size: size) ?? .systemFont(ofSize: size)
    }

    @discardableResult
    func configure(spans: [TokenSpan], structureVersion: Int, activeIndex: Int?, vertical: Bool,
                   fontName: String, fontScale: CGFloat, showFurigana: Bool,
                   ink: UIColor, hi: UIColor) -> Bool {
        let inkChanged = !Self.sameColor(inkColor, ink)
        inkColor = ink; hiColor = hi

        let key = Self.structureHash(version: structureVersion, vertical: vertical,
                                     showFurigana: showFurigana, fontName: fontName, fontScale: fontScale)
        var structureChanged = false
        if key != structureKey {
            if keepsPlaceAcrossReflow, let point = viewportCenter?() {
                reflowAnchor = tokenIndex(at: point)
            }
            structureKey = key
            self.spans = spans
            self.vertical = vertical
            self.showFurigana = showFurigana
            self.fontName = fontName
            self.fontScale = fontScale
            structureChanged = true
        }
        if structureChanged || inkChanged {
            rebuild()
            invalidateTiles()
        }
        self.activeIndex = activeIndex
        updateHighlight()
        return structureChanged
    }

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

    private func rebuild() {
        let font = readingFont(fontSize)
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: inkColor]

        let out = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for span in spans {
            let start = out.length
            let display = vertical ? Self.uprightDigits(span.surface) : span.surface
            let placement = showFurigana
                ? Furigana.place(surface: display, reading: span.reading) : nil

            let piece: NSMutableAttributedString
            if let placement {
                let chars = Array(display)
                let prefix = String(chars[..<placement.range.lowerBound])
                let core = Self.wordJoined(String(chars[placement.range]))
                let suffix = String(chars[placement.range.upperBound...])
                piece = NSMutableAttributedString(string: prefix + core + suffix, attributes: baseAttrs)

                let rubyFont = readingFont(fontSize * 0.5)
                let ann = CTRubyAnnotationCreateWithAttributes(
                    .center, .auto, .before, placement.reading as CFString,
                    [kCTFontAttributeName: rubyFont,
                     kCTForegroundColorAttributeName: inkColor.cgColor] as CFDictionary)
                piece.addAttribute(NSAttributedString.Key(kCTRubyAnnotationAttributeName as String),
                                   value: ann,
                                   range: NSRange(location: (prefix as NSString).length,
                                                  length: (core as NSString).length))
            } else {
                piece = NSMutableAttributedString(string: display, attributes: baseAttrs)
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
        drawLock.lock()
        ctFrame = nil
        frameSize = .zero
        drawLock.unlock()

        accessibilityLabel = spans.map(\.surface).joined()
    }

    func fittingSize(crossAxis: CGFloat) -> CGSize {
        guard let framesetter, crossAxis > 1 else { return .zero }
        let suggest = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRangeMake(0, 0), nil,
            CGSize(width: crossAxis, height: .greatestFiniteMagnitude), nil)
        let main = ceil(suggest.height) + fontSize
        return vertical ? CGSize(width: main, height: crossAxis)
                        : CGSize(width: crossAxis, height: main)
    }

    private func currentFrame() -> CTFrame? {
        guard let framesetter, bounds.width > 1, bounds.height > 1 else { return nil }
        if let f = ctFrame, frameSize == bounds.size { return f }
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: bounds.size))
        let frameAttrs: CFDictionary? = vertical
            ? [kCTFrameProgressionAttributeName: CTFrameProgression.rightToLeft.rawValue] as CFDictionary
            : nil
        let f = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, frameAttrs)
        drawLock.lock()
        ctFrame = f
        frameSize = bounds.size
        drawLock.unlock()
        lines = (CTFrameGetLines(f) as? [CTLine]) ?? []
        lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        if !lines.isEmpty { CTFrameGetLineOrigins(f, CFRangeMake(0, 0), &lineOrigins) }
        lineRanges = lines.map { let r = CTLineGetStringRange($0); return NSRange(location: r.location, length: r.length) }
        return f
    }

    private func linesForToken(_ range: NSRange) -> Range<Int> {
        guard !lineRanges.isEmpty else { return 0..<0 }
        let tEnd = range.location + range.length
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

    override func layoutSubviews() {
        super.layoutSubviews()
        highlightLayer.frame = bounds
        _ = currentFrame()
        if tiledSize != bounds.size {
            tiledSize = bounds.size
            invalidateTiles()
        } else {
            refreshTiles()
        }
        updateHighlight()
    }

    func setVisibleRect(_ rect: CGRect) {
        visibleRect = rect
        refreshTiles()
    }

    private func invalidateTiles() {
        tileGeneration &+= 1
        tileLayers.values.forEach { $0.removeFromSuperlayer() }
        tileLayers.removeAll()
        refreshTiles()
    }

    private func refreshTiles() {
        let side = Self.tileSide
        guard bounds.width > 1, bounds.height > 1, !visibleRect.isEmpty,
              let frame = currentFrame() else { return }

        let margin = vertical
            ? visibleRect.insetBy(dx: -side, dy: 0)
            : visibleRect.insetBy(dx: 0, dy: -side)
        let area = margin.intersection(bounds)
        guard !area.isNull, !area.isEmpty else { return }

        let firstCol = max(0, Int(floor(area.minX / side)))
        let lastCol = Int(ceil(area.maxX / side)) - 1
        let firstRow = max(0, Int(floor(area.minY / side)))
        let lastRow = Int(ceil(area.maxY / side)) - 1
        guard lastCol >= firstCol, lastRow >= firstRow else { return }

        let canvasHeight = bounds.height
        let ink = inkColor.cgColor
        let displayScale = traitCollection.displayScale
        let scale = displayScale > 0 ? displayScale : (window?.screen.scale ?? 2)
        let generation = tileGeneration

        var wanted = Set<TileKey>()
        for row in firstRow...lastRow {
            for col in firstCol...lastCol {
                let key = TileKey(col: col, row: row)
                wanted.insert(key)
                guard tileLayers[key] == nil else { continue }
                let rect = CGRect(x: CGFloat(col) * side, y: CGFloat(row) * side,
                                  width: side, height: side)
                tileLayers[key] = makeTileLayer(rect)
                renderTile(key: key, rect: rect, frame: frame, canvasHeight: canvasHeight,
                           ink: ink, scale: scale, generation: generation)
            }
        }
        for (key, layer) in tileLayers where !wanted.contains(key) {
            layer.removeFromSuperlayer()
            tileLayers[key] = nil
        }
    }

    private func makeTileLayer(_ rect: CGRect) -> CALayer {
        let tile = CALayer()
        tile.frame = rect
        tile.contentsGravity = .resize
        tile.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.insertSublayer(tile, below: highlightLayer)
        return tile
    }

    private func renderTile(key: TileKey, rect: CGRect, frame: CTFrame, canvasHeight: CGFloat,
                            ink: CGColor, scale: CGFloat, generation: Int) {
        let side = Self.tileSide
        tileQueue.async { [weak self] in
            let pixels = Int((side * scale).rounded())
            guard pixels > 0,
                  let ctx = CGContext(data: nil, width: pixels, height: pixels,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            ctx.scaleBy(x: scale, y: scale)
            ctx.textMatrix = .identity
            ctx.translateBy(x: -rect.minX, y: -(canvasHeight - rect.minY - side))
            ctx.setFillColor(ink)
            CTFrameDraw(frame, ctx)
            guard let image = ctx.makeImage() else { return }
            DispatchQueue.main.async {
                guard let self, self.tileGeneration == generation,
                      let tile = self.tileLayers[key] else { return }
                tile.contentsScale = scale
                tile.contents = image
            }
        }
    }

    private func updateHighlight() {
        highlightLayer.fillColor = hiColor.cgColor
        guard ctFrame != nil, let active = activeIndex,
              active >= 0, active < tokenRanges.count else {
            highlightLayer.path = nil
            return
        }
        let rects = tokenRects(tokenRanges[active])
        guard !rects.isEmpty else { highlightLayer.path = nil; return }
        let path = CGMutablePath()
        for r in rects {
            let tl = CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
            path.addRoundedRect(in: tl.insetBy(dx: -4, dy: -3), cornerWidth: 6, cornerHeight: 6)
        }
        highlightLayer.path = path
    }

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

    func activeLineCenter() -> CGFloat? {
        activeIndex.flatMap(lineCenter(forToken:))
    }

    func lineCenter(forToken token: Int) -> CGFloat? {
        guard token >= 0, token < tokenRanges.count, currentFrame() != nil else { return nil }
        guard let i = linesForToken(tokenRanges[token]).first, i < lines.count else { return nil }
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(lines[i], &ascent, &descent, &leading)
        let origin = lineOrigins[i]
        if vertical {
            return origin.x + (ascent - descent) / 2
        }
        return bounds.height - origin.y - (ascent - descent) / 2
    }

    func tokenIndex(at point: CGPoint) -> Int? {
        guard currentFrame() != nil else { return nil }
        let flipped = CGPoint(x: point.x, y: bounds.height - point.y)
        guard let li = lineIndex(at: flipped), li < lineRanges.count else { return nil }
        let lr = lineRanges[li]
        return tokenRanges.firstIndex {
            $0.location + $0.length > lr.location && $0.location < lr.location + lr.length
        }
    }

    func takeReflowAnchor() -> Int? {
        defer { reflowAnchor = nil }
        return reflowAnchor
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard currentFrame() != nil else { onTapBackground(); return }
        let p = g.location(in: self)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        guard let li = lineIndex(at: flipped) else { onTapBackground(); return }
        let lr = lineRanges[li]
        for (idx, range) in tokenRanges.enumerated() {
            guard range.location < lr.location + lr.length, range.location + range.length > lr.location else {
                if range.location >= lr.location + lr.length { break }
                continue
            }
            for r in tokenRects(range) where r.insetBy(dx: -4, dy: -4).contains(flipped) {
                onTapToken(idx)
                return
            }
        }
        onTapBackground()
    }

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

    static func wordJoined(_ s: String) -> String {
        s.count > 1 ? s.map(String.init).joined(separator: "\u{2060}") : s
    }

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
}
