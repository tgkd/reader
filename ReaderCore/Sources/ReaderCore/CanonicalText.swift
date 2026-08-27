import Foundation

public struct CanonicalText: Equatable, Hashable, Sendable {
    public let value: String

    public init(_ raw: String) {
        self.value = Normalize.nfkc(raw)
    }

    public init(alreadyCanonical value: String) {
        self.value = value
    }
}
