import SwiftUI

/// Reading preferences exposed in Settings. The face applies to the reader body
/// AND the Japanese content titles (library rows, reader title); the size applies
/// to the reader body only. The wordmark, UI labels, and dictionary keep Mincho.

/// Reading typeface. Each maps to a system Japanese font's PostScript name;
/// `UIFont(name:)` falls back to the system font if a face is unavailable.
/// Display names are localized (chrome).
enum ReadingFont: String, CaseIterable, Codable, Identifiable {
    case mincho, gothic, rounded

    var id: String { rawValue }

    var psName: String {
        switch self {
        case .mincho:  return "HiraMinProN-W3"   // serif (the original default)
        case .gothic:  return "HiraKakuProN-W3"  // sans
        case .rounded: return "HiraMaruProN-W4"  // rounded sans
        }
    }

    /// The face as a SwiftUI `Font` at `size` — for content titles drawn outside
    /// the CoreText reader (library rows, the reader's title bar).
    func font(_ size: CGFloat) -> Font { .custom(psName, size: size) }

    var displayName: String {
        switch self {
        case .mincho:  return L10n.fontMincho
        case .gothic:  return L10n.fontGothic
        case .rounded: return L10n.fontRounded
        }
    }
}

/// Reading text size — a multiplier on the reader's base point size
/// (`RubyTextView.fontSize`).
enum ReadingSize: String, CaseIterable, Codable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var scale: CGFloat {
        switch self {
        case .small:  return 0.85
        case .medium: return 1.0
        case .large:  return 1.2
        }
    }

    var displayName: String {
        switch self {
        case .small:  return L10n.sizeSmall
        case .medium: return L10n.sizeMedium
        case .large:  return L10n.sizeLarge
        }
    }
}

/// Reader writing direction — vertical (縦書き) or horizontal (横書き). A global
/// preference persisted in `AppModel`; the reader's quick-toggle and the Settings
/// picker both drive it. `tate` (vertical) is the default for Japanese prose.
enum Orientation: String, CaseIterable, Codable, Identifiable {
    case tate, yoko

    var id: String { rawValue }
    var isVertical: Bool { self == .tate }

    var displayName: String {
        switch self {
        case .tate: return L10n.directionVertical
        case .yoko: return L10n.directionHorizontal
        }
    }
}
