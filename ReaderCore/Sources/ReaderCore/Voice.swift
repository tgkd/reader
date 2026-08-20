import Foundation

public struct Voice: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let shizuka = Voice(id: "WQz3clzUdMqvBf0jswZQ", name: "Shizuka")

    public static let george = Voice(id: "JBFqnCBsd6RMkjVDRZzb", name: "George")

    public static let seed: [Voice] = [
        shizuka,
        Voice(id: "deKmbWEKZdwxcKxxcfvP", name: "Maiko"),
        Voice(id: "17ljzcHzSunXNkdixIEa", name: "Hirokoji"),
        Voice(id: "3JDquces8E8bkmvbh6Bc", name: "Otani"),
        Voice(id: "T7yYq3WpB94yAuOXraRi", name: "Konoha"),
    ]

    public static let retired: [Voice] = [
        Voice(id: "Mv8AjrYZCBkdsmDHNwcB", name: "Ishibashi"),
        Voice(id: "ss9cJxDAEMXP4wfQ3GPr", name: "Daisuke"),
        george,
    ]

    public static let allKnown: [Voice] = seed + retired
}

public enum SynthesisLimits {
    public static let maxRequestChars = 4_500
}

public enum LegacyAudioCache {
    public static let modelIDs = ["eleven_flash_v2_5", "eleven_v3", "eleven_multilingual_v2"]
}
