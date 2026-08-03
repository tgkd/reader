import AVFAudio
import Observation
import ReaderCore

/// Plays short narration samples for the Settings voice picker. Each sample is
/// the same fixed sentence synthesized once per voice through the normal gated
/// TTS path and cached content-addressed — so a demo costs ElevenLabs credits
/// only the first time it is ever played for a voice, and is instant after.
@MainActor
@Observable
final class VoiceDemoPlayer {
    /// Public-domain opener — short (~20 chars) but characteristic prose, so a
    /// few seconds of audio carry the voice's register.
    static let sampleText = "吾輩は猫である。名前はまだ無い。"

    /// Voice whose sample is being synthesized (spinner) / played (stop icon).
    private(set) var synthesizingID: String?
    private(set) var playingID: String?

    private var player: AVAudioPlayer?
    private var delegate: DemoDelegate?
    private var task: Task<Void, Never>?

    /// Play the voice's sample, or stop if it's already busy/playing.
    func toggle(_ voice: Voice, services: AppServices) {
        guard playingID != voice.id, synthesizingID != voice.id else { stop(); return }
        stop()
        synthesizingID = voice.id
        task = Task { [weak self] in
            let request = SynthesisRequest(text: Self.sampleText, voice: voice)
            // Legacy-model entries count: a sample bought under the previous default
            // is the same sentence in the same voice, and replaying it is free.
            var synth = services.audioStore.loadAllowingLegacyModel(request)?.audio
            if synth == nil {
                // Cache miss = a paid request. Revalidate the entitlement locally
                // first: this sheet can outlive the check that revealed the voice
                // picker, and the Worker's 403 is only meant to be the backstop.
                guard await services.isSubscribed() else { self?.synthesizingID = nil; return }
                // Stop / dismiss / another voice cancels this task, but the entitlement
                // lookup above is a suspension its continuation still returns from —
                // entering the coordinator afterwards would start a paid sample the
                // user already cancelled (rapid voice switching = one bill per tap).
                guard !Task.isCancelled else { return }
                // Route through the coordinator, which owns the request and saves
                // the result the moment it lands. Dismissing Settings / tapping Stop
                // / switching voices then only DETACHES this UI — previously it
                // cancelled a request ElevenLabs may already have billed, leaving no
                // cached sample, so the next tap paid for it again. It also dedupes
                // a double tap on the same voice into one request.
                synth = try? await services.synthesis.task(for: request).value
            }
            guard let self, !Task.isCancelled else { return }
            self.synthesizingID = nil
            guard let synth, let p = try? AVAudioPlayer(data: synth.audio) else { return }
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            try? AVAudioSession.sharedInstance().setActive(true)
            let d = DemoDelegate()
            d.onFinish = { [weak self] in self?.stop() }
            p.delegate = d
            self.delegate = d
            self.player = p
            self.playingID = voice.id
            p.play()
        }
    }

    /// Cancel any in-flight sample and release the audio session.
    func stop() {
        task?.cancel()
        task = nil
        player?.stop()
        player = nil
        delegate = nil
        if playingID != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        synthesizingID = nil
        playingID = nil
    }
}

/// `AVAudioPlayer` needs an NSObject delegate; forwards natural finish so the
/// row's stop icon reverts (mirrors ReaderModel's `PlayerDelegate`).
private final class DemoDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { onFinish?() }
    }
}
