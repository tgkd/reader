import Foundation
import ReaderCore

actor TokenizerWorker {
    private var tokenizer: MeCabTokenizer?
    private var initAttempted = false

    func tokenize(_ text: String) -> [Token]? {
        if !initAttempted {
            initAttempted = true
            tokenizer = try? MeCabTokenizer()
        }
        return tokenizer?.tokenize(text)
    }

    func readings(of surfaces: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for surface in surfaces {
            guard let reading = reading(of: surface) else { continue }
            out[surface] = reading
        }
        return out
    }

    private func reading(of surface: String) -> String? {
        let normalized = Normalize.nfkc(surface)
        guard let tokens = tokenize(normalized),
              tokens.map(\.surface).joined() == normalized else { return nil }
        let readings = tokens.compactMap(\.reading)
        guard readings.count == tokens.count, !readings.isEmpty else { return nil }
        return readings.joined()
    }
}
