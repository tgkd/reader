import Foundation

public enum Normalize {
    public static func nfkc(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping
    }
}
