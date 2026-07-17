import Foundation
import ReaderCore

/// Serves the captured ElevenLabs fixtures bundled in the app (offline, no key).
/// Not in the playback chain — `AppServices` keeps one instance solely for the
/// Library's "is this cached?" probe (`hasFixture`), identical in every build
/// flavor.
///
/// Matches a request to a fixture by NFKC text AND voice + model, so it stays
/// consistent with `SynthesisRequest.cacheKey` (`ContentKey`) and the Worker
/// path — a different voice/model is a miss, not a wrong-voice hit. The fixture
/// wire shape is `{text, voiceId, modelId, alignment}` with the audio in a
/// sibling `.mp3` (the capture script strips `audio_base64`), so alignment and
/// audio load separately.
final class FixtureTTSService: TTSService {
    enum FixtureError: Error { case notGenerated }

    private struct Fixture: Decodable {
        let text: String
        let voiceId: String
        let modelId: String
        let alignment: Alignment
    }

    func synthesize(_ request: SynthesisRequest) async throws -> SynthesizedAudio {
        guard let m = match(text: request.text, voiceId: request.voice.id, modelId: request.model.rawValue),
              let mp3 = Bundle.main.url(forResource: m.name, withExtension: "mp3"),
              let audio = try? Data(contentsOf: mp3) else {
            throw FixtureError.notGenerated
        }
        return SynthesizedAudio(audio: audio, alignment: m.alignment, text: m.text)
    }

    /// Library "cached" hint: is there offline audio for this text at the default
    /// voice/model? (UI-only; the real cache state is `GeneratedAudioStore`.)
    func hasFixture(for text: String) -> Bool {
        match(text: text, voiceId: Voice.george.id, modelId: SynthesisModel.multilingualV2.rawValue) != nil
    }

    private func match(text: String, voiceId: String, modelId: String)
        -> (name: String, text: String, alignment: Alignment)? {
        let target = Normalize.nfkc(text)
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let fx = try? JSONDecoder().decode(Fixture.self, from: data),
                  Normalize.nfkc(fx.text) == target,
                  fx.voiceId == voiceId, fx.modelId == modelId else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            guard Bundle.main.url(forResource: name, withExtension: "mp3") != nil else { continue }
            return (name, fx.text, fx.alignment)
        }
        return nil
    }
}
