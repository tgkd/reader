import UIKit
import ReaderCore

@MainActor
final class SynthesisCoordinator {
    private let tts: TTSService
    private let store: GeneratedAudioStore
    private var inFlight: [ContentKey: Task<SynthesizedAudio, Error>] = [:]

    init(tts: TTSService, store: GeneratedAudioStore) {
        self.tts = tts
        self.store = store
    }

    func isSynthesizing(_ key: ContentKey) -> Bool { inFlight[key] != nil }

    func task(for request: SynthesisRequest) -> Task<SynthesizedAudio, Error> {
        let key = request.cacheKey
        if let running = inFlight[key] { return running }
        let assertion = BackgroundAssertion(name: "tts-synthesis")
        let task = Task { [tts, store] in
            defer { assertion.end() }
            let synth = try await tts.synthesize(request)
            store.save(synth, for: key)
            return synth
        }
        inFlight[key] = task
        Task { [weak self] in
            _ = try? await task.value
            if self?.inFlight[key] == task { self?.inFlight[key] = nil }
        }
        return task
    }

    func cancel(_ key: ContentKey) {
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }

    func cancelAndWait(_ key: ContentKey) async {
        guard let task = inFlight[key] else { return }
        task.cancel()
        inFlight[key] = nil
        _ = try? await task.value
    }
}

@MainActor
final class BackgroundAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
