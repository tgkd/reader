import Foundation
import CryptoKit

/// Stable cache key for one unit of synthesized narration: a hash of the exact
/// text sent to TTS plus the voice and model. Identical `(text, voice, model)` →
/// identical key, so a chapter's audio + alignment is generated once and reused
/// for free (and offline) on every re-read. Text is NFKC-normalized first — the
/// single-normalization rule — so encoding-only differences share a key.
public struct ContentKey: Hashable, CustomStringConvertible {
    public let value: String

    public init(text: String, voice: String, model: String) {
        let normalized = Normalize.nfkc(text)
        // U+001F (unit separator) can't occur in normalized text, so the parts
        // can't collide across the boundary.
        let payload = "\(model)\u{1f}\(voice)\u{1f}\(normalized)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        self.value = digest.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { value }
}
