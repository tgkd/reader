import SwiftUI

/// A small round/rounded icon button with a hairline border — the design's
/// 34px header/chrome control (settings, membership, add, orientation, theme).
/// Renders an SF Symbol so the chrome reads the same in any language.
struct IconButton: View {
    enum Outline { case circle, rounded }

    var systemImage: String
    var font: Font = .system(size: 15)
    var foreground: Color
    var outline: Outline = .circle
    var size: CGFloat = 34
    /// VoiceOver label — an icon-only control, so callers pass a spoken label.
    var label: String
    var action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .overlay(border)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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

