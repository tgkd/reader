import Foundation

public struct DocumentMetadata: Equatable, Sendable {
    public var title: String?
    public var author: String?
    public var writingMode: WritingMode?

    public init(title: String? = nil, author: String? = nil, writingMode: WritingMode? = nil) {
        self.title = title
        self.author = author
        self.writingMode = writingMode
    }
}

public protocol DocumentImporter {
    func chapters() async throws -> [Chapter]
    func metadata() async throws -> DocumentMetadata
}

public extension DocumentImporter {
    func metadata() async throws -> DocumentMetadata { DocumentMetadata() }
}
