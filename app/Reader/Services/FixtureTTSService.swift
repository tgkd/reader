import Foundation
import ReaderCore

final class FixtureTTSService: TTSService {
    enum FixtureError: Error { case notGenerated }

    private struct Fixture: Decodable {
        let text: String
        let voiceId: String
        let modelId: String
        let alignment: Alignment
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        guard let m = match(text: request.text, voiceId: request.voice.id),
              let mp3 = Bundle.main.url(forResource: m.name, withExtension: "mp3"),
              let audio = try? Data(contentsOf: mp3) else {
            throw FixtureError.notGenerated
        }
        return SynthesizedAudio(audio: audio, alignment: m.alignment, text: m.text)
    }

    func hasFixture(for text: String) -> Bool {
        match(text: text, voiceId: Voice.george.id) != nil
    }

    private func match(text: String, voiceId: String)
        -> (name: String, text: String, alignment: Alignment)? {
        let target = Normalize.nfkc(text)
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let fx = try? JSONDecoder().decode(Fixture.self, from: data),
                  Normalize.nfkc(fx.text) == target,
                  fx.voiceId == voiceId else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard Bundle.main.url(forResource: name, withExtension: "mp3") != nil else { continue }
            return (name, fx.text, fx.alignment)
        }
        return nil
    }
}
