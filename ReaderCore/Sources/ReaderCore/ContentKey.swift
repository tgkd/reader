import Foundation
import CryptoKit

public struct ContentKey: Hashable, CustomStringConvertible {
    public let value: String

    public init(text: String, voice: String) {
        self.init(canonical: CanonicalText(text), voice: voice)
    }

    public init(text: String, voice: String, legacyModel: String) {
        self.init(canonical: CanonicalText(text), voice: voice, legacyModel: legacyModel)
    }

    public init(canonical text: CanonicalText, voice: String) {
        self.init(payload: "\(voice)\u{1f}\(text.value)")
    }

    public init(canonical text: CanonicalText, voice: String, legacyModel: String) {
        self.init(payload: "\(legacyModel)\u{1f}\(voice)\u{1f}\(text.value)")
    }

    private init(payload: String) {
        let digest = SHA256.hash(data: Data(payload.utf8))
        self.value = digest.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { value }
}
