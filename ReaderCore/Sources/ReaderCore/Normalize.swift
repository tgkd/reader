import Foundation

/// Text normalization applied identically before tokenizing AND before sending
/// text to TTS, so the tokenizer's characters and the API's returned
/// `characters[]` line up. NFKC folds full-width/half-width (zenkaku/hankaku)
/// and compatibility forms to a single canonical representation.
public enum Normalize {
    /// NFKC normalization (compatibility decomposition + canonical composition).
    public static func nfkc(_ s: String) -> String {
        s.precomposedStringWithCompatibilityMapping
    }
}
