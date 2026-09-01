import Foundation
import Observation
import ReaderCore

@MainActor
@Observable
final class VoiceCatalog {
    private static let servedKey = "reader.voiceCatalog.served"
    private static let knownKey = "reader.voiceCatalog.known"
    private static let limitKey = "reader.voiceCatalog.maxRequestChars"

    private(set) var selectable: [Voice]

    private let baseURL: URL
    private let userId: @Sendable () -> String?
    private let session: URLSession
    private let defaults: UserDefaults

    init(baseURL: URL,
         userId: @escaping @Sendable () -> String?,
         session: URLSession = .shared,
         defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        self.userId = userId
        self.session = session
        self.defaults = defaults
        self.selectable = Self.decodeServed(from: defaults) ?? Voice.seed
        remember(Voice.allKnown.map(\.id) + selectable.map(\.id))
    }

    func refresh() async {
        guard let catalog = await fetch(), !catalog.voices.isEmpty else { return }
        selectable = catalog.voices
        if let data = try? JSONEncoder().encode(catalog.voices) {
            defaults.set(data, forKey: Self.servedKey)
        }
        if let limit = catalog.maxRequestChars, SynthesisLimits.servedRange.contains(limit) {
            defaults.set(limit, forKey: Self.limitKey)
        }
        remember(catalog.voices.map(\.id))
    }

    nonisolated static func maxRequestChars(_ defaults: UserDefaults = .standard) -> Int {
        let served = defaults.integer(forKey: limitKey)
        return SynthesisLimits.servedRange.contains(served) ? served : SynthesisLimits.maxRequestChars
    }

    func voice(id: String) -> Voice? {
        selectable.first { $0.id == id }
            ?? Voice.allKnown.first { $0.id == id }
            ?? Self.decodeServed(from: defaults)?.first { $0.id == id }
    }

    var knownIDs: [String] {
        let stored = defaults.stringArray(forKey: Self.knownKey) ?? []
        return Array(Set(stored).union(Voice.allKnown.map(\.id)))
    }

    private func remember(_ ids: [String]) {
        let merged = Set(defaults.stringArray(forKey: Self.knownKey) ?? []).union(ids)
        defaults.set(Array(merged).sorted(), forKey: Self.knownKey)
    }

    private func fetch() async -> ServedCatalog? {
        guard let user = userId(), !user.isEmpty else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("tts/voices"))
        request.setValue(user, forHTTPHeaderField: "X-User-ID")
        request.timeoutInterval = 15
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(ServedCatalog.self, from: data)
        else { return nil }
        return ServedCatalog(voices: decoded.voices.filter { !$0.id.isEmpty && !$0.name.isEmpty },
                             maxRequestChars: decoded.maxRequestChars)
    }

    private static func decodeServed(from defaults: UserDefaults) -> [Voice]? {
        guard let data = defaults.data(forKey: servedKey),
              let decoded = try? JSONDecoder().decode([Voice].self, from: data),
              !decoded.isEmpty
        else { return nil }
        return decoded
    }

    private struct ServedCatalog: Decodable {
        let voices: [Voice]
        let maxRequestChars: Int?

        enum CodingKeys: String, CodingKey {
            case voices
            case maxRequestChars = "max_request_chars"
        }
    }
}
