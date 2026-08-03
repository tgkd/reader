import Foundation

public struct Voice: Identifiable, Codable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let isPremade: Bool

    public init(id: String, name: String, isPremade: Bool) {
        self.id = id
        self.name = name
        self.isPremade = isPremade
    }

    public static let shizuka = Voice(id: "WQz3clzUdMqvBf0jswZQ", name: "Shizuka", isPremade: false)

    public static let george = Voice(id: "JBFqnCBsd6RMkjVDRZzb", name: "George", isPremade: true)

    public static let catalog: [Voice] = [
        shizuka,
        Voice(id: "deKmbWEKZdwxcKxxcfvP", name: "Maiko", isPremade: false),
        Voice(id: "17ljzcHzSunXNkdixIEa", name: "Hirokoji", isPremade: false),
        Voice(id: "Mv8AjrYZCBkdsmDHNwcB", name: "Ishibashi", isPremade: false),
        Voice(id: "ss9cJxDAEMXP4wfQ3GPr", name: "Daisuke", isPremade: false),
        george,
    ]
}

public enum SynthesisLimits {
    public static let maxRequestChars = 4_500
}

public enum LegacyAudioCache {
    public static let modelIDs = ["eleven_flash_v2_5", "eleven_v3", "eleven_multilingual_v2"]
}
