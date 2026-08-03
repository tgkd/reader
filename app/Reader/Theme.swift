import SwiftUI

enum ThemeName: String, CaseIterable, Codable {
    case paper, white, sepia, night

    var symbol: String {
        switch self {
        case .paper: return "sun.max"
        case .white: return "sun.max.fill"
        case .sepia: return "sunset"
        case .night: return "moon.stars"
        }
    }

    var next: ThemeName {
        let all = ThemeName.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var displayName: String {
        switch self {
        case .paper: return L10n.themePaper
        case .white: return L10n.themeWhite
        case .sepia: return L10n.themeSepia
        case .night: return L10n.themeNight
        }
    }

    var isDark: Bool { self == .night }
    var theme: Theme { Theme(name: self) }
}

struct Theme: Equatable {
    let name: ThemeName
    let bg: Color
    let surface: Color
    let ink: Color
    let muted: Color
    let hair: Color
    let accent: Color
    let hi: Color
    let soft: Color
    let onAccent: Color

    init(name: ThemeName) {
        self.name = name
        switch name {
        case .paper:
            bg = Color(hex: 0xf4f1e9);  surface = Color(hex: 0xfbf8f1)
            ink = Color(hex: 0x36312a); muted = Color(hex: 0xa59c8d)
            hair = Color(hex: 0x36312a, opacity: 0.12); accent = Color(hex: 0x44617b)
            hi = Color(hex: 0x44617b, opacity: 0.14)
            soft = Color(hex: 0x36312a, opacity: 0.05)
            onAccent = Color(hex: 0xfbf8f1)
        case .white:
            bg = Color(hex: 0xffffff);  surface = Color(hex: 0xffffff)
            ink = Color(hex: 0x1c1c1e); muted = Color(hex: 0x8e8e93)
            hair = Color(hex: 0x000000, opacity: 0.10); accent = Color(hex: 0x1c1c1e)
            hi = Color(hex: 0x000000, opacity: 0.12)
            soft = Color(hex: 0x000000, opacity: 0.05)
            onAccent = Color(hex: 0xffffff)
        case .sepia:
            bg = Color(hex: 0xece0ca);  surface = Color(hex: 0xf4ead7)
            ink = Color(hex: 0x473a27); muted = Color(hex: 0xa18d6e)
            hair = Color(hex: 0x473a27, opacity: 0.14); accent = Color(hex: 0xa4663a)
            hi = Color(hex: 0xa4663a, opacity: 0.18)
            soft = Color(hex: 0x473a27, opacity: 0.06)
            onAccent = Color(hex: 0xf4ead7)
        case .night:
            bg = Color(hex: 0x161613);  surface = Color(hex: 0x1f1e1a)
            ink = Color(hex: 0xdcd6c8); muted = Color(hex: 0x736d60)
            hair = Color(hex: 0xdcd6c8, opacity: 0.12); accent = Color(hex: 0xc9a961)
            hi = Color(hex: 0xc9a961, opacity: 0.20)
            soft = Color(hex: 0xdcd6c8, opacity: 0.06)
            onAccent = Color(hex: 0x161613)
        }
    }
}

enum Mincho {
    static let psName = "HiraMinProN-W3"
    static func font(_ size: CGFloat) -> Font { .custom(psName, size: size) }
    static func uiFont(_ size: CGFloat) -> UIFont { UIFont(name: psName, size: size) ?? .systemFont(ofSize: size) }
}

extension Color {
    init(hex: UInt, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
    var ui: UIColor { UIColor(self) }
}

extension EnvironmentValues {
    @Entry var theme = Theme(name: .paper)
}
