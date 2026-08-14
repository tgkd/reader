import Foundation

public enum VariationSelector {
    public static func isSelector(_ scalar: Unicode.Scalar) -> Bool {
        (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
    }

    public static func present(in text: String) -> Bool {
        text.unicodeScalars.contains(where: isSelector)
    }

    public static func stripped(_ text: String) -> String {
        guard present(in: text) else { return text }
        return String(String.UnicodeScalarView(text.unicodeScalars.filter { !isSelector($0) }))
    }

    public static func sameWord(_ a: String, _ b: String) -> Bool {
        a == b || stripped(a) == stripped(b)
    }
}
