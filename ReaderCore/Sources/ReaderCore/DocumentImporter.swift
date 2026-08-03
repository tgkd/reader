import Foundation

public protocol DocumentImporter {
    func chapters() async throws -> [Chapter]
}
