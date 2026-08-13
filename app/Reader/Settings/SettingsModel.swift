import SwiftUI

enum ReadingFont: String, CaseIterable, Codable, Identifiable {
    case mincho, gothic, rounded

    var id: String { rawValue }

    var psName: String {
        switch self {
        case .mincho:  return "HiraMinProN-W3"
        case .gothic:  return "HiraKakuProN-W3"
        case .rounded: return "HiraMaruProN-W4"
        }
    }

    func font(_ size: CGFloat) -> Font { .custom(psName, size: size) }

    var displayName: String {
        switch self {
        case .mincho:  return L10n.fontMincho
        case .gothic:  return L10n.fontGothic
        case .rounded: return L10n.fontRounded
        }
    }
}

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

enum Orientation: String, Codable {
    case tate, yoko

    var isVertical: Bool { self == .tate }
}
