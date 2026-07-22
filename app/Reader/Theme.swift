import SwiftUI

/// The Yomi design system as resolved color tokens, injected through the
/// environment so views read `@Environment(\.theme)` and never hardcode colors.
/// Switching theme swaps the whole token set at the root — the SwiftUI analogue
/// of the design's CSS custom properties (`--bg`, `--ink`, `--hi`, …).
enum ThemeName: String, CaseIterable, Codable {
    case paper, white, sepia, night

    /// SF Symbol for the reader's appearance toggle, reflecting the current theme
    /// (light → brightest → warm → dark). Language-neutral, unlike the old 紙/茶/夜 glyphs.
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

    /// Localized name for the Settings theme picker (chrome).
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

/// One resolved palette. Base values come from the Yomi design's `THEMES` map;
/// each theme carries its own accent (indigo / ink / coral / gold) — only sepia
/// keeps the mockup's shared terracotta.
struct Theme: Equatable {
    let name: ThemeName
    let bg: Color
    let surface: Color
    let ink: Color
    let muted: Color
    let hair: Color
    let accent: Color
    let hi: Color       // active-token highlight background
    let hiInk: Color    // active-token text
    let soft: Color     // faint fills (progress track, example box)
    let onAccent: Color // text/icon drawn on top of an accent fill (e.g. the speed pill)

    init(name: ThemeName) {
        self.name = name
        switch name {
        case .paper:
            // Daylight cream takes a muted navy-gray (紺鼠) accent — aizome on washi.
            bg = Color(hex: 0xf4f1e9);  surface = Color(hex: 0xfbf8f1)
            ink = Color(hex: 0x36312a); muted = Color(hex: 0xa59c8d)
            hair = Color(hex: 0x36312a, opacity: 0.12); accent = Color(hex: 0x44617b)
            hi = Color(hex: 0x44617b, opacity: 0.14);   hiInk = Color(hex: 0x22333e)
            soft = Color(hex: 0x36312a, opacity: 0.05)
            onAccent = Color(hex: 0xfbf8f1)
        case .white:
            // Pure white with iOS-native neutrals (label/secondaryLabel grays);
            // the accent is near-black ink — a monochrome scheme with a graphite highlight.
            bg = Color(hex: 0xffffff);  surface = Color(hex: 0xffffff)
            ink = Color(hex: 0x1c1c1e); muted = Color(hex: 0x8e8e93)
            hair = Color(hex: 0x000000, opacity: 0.10); accent = Color(hex: 0x1c1c1e)
            hi = Color(hex: 0x000000, opacity: 0.12);   hiInk = Color(hex: 0x000000)
            soft = Color(hex: 0x000000, opacity: 0.05)
            onAccent = Color(hex: 0xffffff)
        case .sepia:
            bg = Color(hex: 0xece0ca);  surface = Color(hex: 0xf4ead7)
            ink = Color(hex: 0x473a27); muted = Color(hex: 0xa18d6e)
            hair = Color(hex: 0x473a27, opacity: 0.14); accent = Color(hex: 0xa4663a)
            hi = Color(hex: 0xa4663a, opacity: 0.18);   hiInk = Color(hex: 0x3c2916)
            soft = Color(hex: 0x473a27, opacity: 0.06)
            onAccent = Color(hex: 0xf4ead7)
        case .night:
            // Dark theme takes a muted moonlit gold accent (moon.stars).
            bg = Color(hex: 0x161613);  surface = Color(hex: 0x1f1e1a)
            ink = Color(hex: 0xdcd6c8); muted = Color(hex: 0x736d60)
            hair = Color(hex: 0xdcd6c8, opacity: 0.12); accent = Color(hex: 0xc9a961)
            hi = Color(hex: 0xc9a961, opacity: 0.20);   hiInk = Color(hex: 0xf1e9dc)
            soft = Color(hex: 0xdcd6c8, opacity: 0.06)
            // The night accent is a light gold; white text on it is low-contrast,
            // so on-accent text uses the dark background instead.
            onAccent = Color(hex: 0x161613)
        }
    }
}

/// Japanese type families used by the design: Mincho (serif) for reading and
/// titles, the system sans (Hiragino Sans on iOS) for UI chrome.
enum Mincho {
    static let psName = "HiraMinProN-W3"
    static func font(_ size: CGFloat) -> Font { .custom(psName, size: size) }
    static func uiFont(_ size: CGFloat) -> UIFont { UIFont(name: psName, size: size) ?? .systemFont(ofSize: size) }
}

extension Color {
    /// Hex literal (0xRRGGBB) + optional opacity, matching the design's rgba().
    init(hex: UInt, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xff) / 255
        let g = Double((hex >> 8) & 0xff) / 255
        let b = Double(hex & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
    /// UIColor bridge for the CoreText reader view.
    var ui: UIColor { UIColor(self) }
}

extension EnvironmentValues {
    /// The active palette. `@Entry` replaces the manual `EnvironmentKey`
    /// boilerplate; the default is a stable struct literal.
    @Entry var theme = Theme(name: .paper)
}
