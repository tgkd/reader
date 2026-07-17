import UIKit
import ReaderCore

/// Session-owned paid synthesis. Tasks are keyed by the request's `ContentKey`
/// so the network work survives the reader that started it: leaving the chapter
/// no longer cancels the request (the paid artifact still lands in the cache),
/// and a reopen awaits the SAME in-flight task instead of starting a duplicate
/// billed synthesis. The result is saved to the audio store the moment it
/// returns — before any caller gets a say — so the money is durable even if
/// every observer is gone. Each task holds a background-task assertion so a
/// brief app switch doesn't suspend the transfer mid-request (the OS caps that
/// grace at ~30 s; audio-mode background time only starts once playback does).
@MainActor
final class SynthesisCoordinator {
    private let tts: TTSService
    private let store: GeneratedAudioStore
    private var inFlight: [ContentKey: Task<SynthesizedAudio, Error>] = [:]

    init(tts: TTSService, store: GeneratedAudioStore) {
        self.tts = tts
        self.store = store
    }

    /// Whether a synthesis for `key` is currently running — drives the reader's
    /// re-attach on reopen (show progress for work already paid for).
    func isSynthesizing(_ key: ContentKey) -> Bool { inFlight[key] != nil }

    /// The in-flight task for `request`, starting one if none exists.
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

    /// Explicit user cancel — the one deliberate way to abandon a paid request.
    func cancel(_ key: ContentKey) {
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }
}

/// One UIKit background-task assertion, ended at most once (explicitly or on
/// the system's expiration callback).
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
