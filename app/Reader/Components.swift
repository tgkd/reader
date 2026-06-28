import SwiftUI

/// A small round/rounded icon button with a hairline border — the design's
/// 34px header/chrome control (theme toggle, add, orientation).
struct IconButton: View {
    enum Outline { case circle, rounded }

    var glyph: String
    var font: Font
    var foreground: Color
    var outline: Outline = .circle
    var size: CGFloat = 34
    /// VoiceOver label — the glyph alone (紙 / 目 / 縦) is meaningless to assistive
    /// tech, so callers pass a spoken label. Falls back to the glyph if omitted.
    var label: String? = nil
    var action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Text(glyph)
                .font(font)
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .overlay(border)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label ?? glyph)
    }

    @ViewBuilder private var border: some View {
        switch outline {
        case .circle: Circle().stroke(theme.hair, lineWidth: 1)
        case .rounded: RoundedRectangle(cornerRadius: 9).stroke(theme.hair, lineWidth: 1)
        }
    }
}

/// A right-pointing play triangle (transport + dictionary "play word").
struct PlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

