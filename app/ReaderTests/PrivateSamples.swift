import Foundation

enum PrivateSamples {
    static var directory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("samples/private", isDirectory: true)
    }

    static func epubs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "epub" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func firstEPUB() -> String? { epubs().first?.path }
}
