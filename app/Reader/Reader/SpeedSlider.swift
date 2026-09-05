import SwiftUI

struct SpeedSlider: View {
    let speeds: [Double]
    let value: Double

    @Environment(\.theme) private var theme

    static func label(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)
    }

    private var index: Int { speeds.firstIndex(of: value) ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 5
            let knobW: CGFloat = 46
            let h = geo.size.height
            let travel = max(0, geo.size.width - inset * 2 - knobW)
            let step = speeds.count > 1 ? travel / CGFloat(speeds.count - 1) : 0
            let center = inset + knobW / 2 + step * CGFloat(index)
            ZStack(alignment: .leading) {
                Capsule().fill(theme.hi)
                    .overlay(Capsule().strokeBorder(theme.hair, lineWidth: 1))
                Capsule().fill(theme.accent)
                    .frame(width: min(geo.size.width, center + knobW / 2 + inset))
                ForEach(speeds.indices, id: \.self) { i in
                    Circle()
                        .fill(i <= index ? theme.onAccent.opacity(0.55) : theme.muted.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .opacity(i == index ? 0 : 1)
                        .position(x: inset + knobW / 2 + step * CGFloat(i), y: h / 2)
                }
                Capsule().fill(theme.surface)
                    .frame(width: knobW, height: h - inset * 2)
                    .overlay {
                        Text("\(Self.label(value))×")
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(theme.ink)
                    }
                    .position(x: center, y: h / 2)
            }
            .clipShape(Capsule())
            .animation(.spring(response: 0.3, dampingFraction: 0.74), value: index)
        }
    }
}
