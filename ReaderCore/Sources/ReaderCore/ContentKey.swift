import Foundation
import CryptoKit

public struct ContentKey: Hashable, CustomStringConvertible {
    public let value: String

    public init(text: String, voice: String) {
        self.init(payload: "\(voice)\u{1f}\(Normalize.nfkc(text))")
    }

    public init(text: String, voice: String, legacyModel: String) {
        self.init(payload: "\(legacyModel)\u{1f}\(voice)\u{1f}\(Normalize.nfkc(text))")
    }

    private init(payload: String) {
        let digest = SHA256.hash(data: Data(payload.utf8))
        self.value = digest.map { String(format: "%02x", $0) }.joined()
    }

    public var description: String { value }
}
