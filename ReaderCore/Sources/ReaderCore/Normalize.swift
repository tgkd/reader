import Foundation

public enum Normalize {
    public static func nfkc(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping
    }

    public static func kanaFold(_ s: String) -> String {
        String(String.UnicodeScalarView(nfkc(s).unicodeScalars.map { scalar in
            if (0x30A1...0x30F6).contains(scalar.value) {
                return Unicode.Scalar(scalar.value - 0x60)!
            }
            return scalar
        }))
    }
}
