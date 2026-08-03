import AVFAudio
import Observation
import ReaderCore

@MainActor
@Observable
final class VoiceDemoPlayer {
    static let sampleText = "吾輩は猫である。名前はまだ無い。"

    private(set) var synthesizingID: String?
    private(set) var playingID: String?

    private var player: AVAudioPlayer?
    private var delegate: DemoDelegate?
    private var task: Task<Void, Never>?

    func toggle(_ voice: Voice, services: AppServices) {
        guard playingID != voice.id, synthesizingID != voice.id else { stop(); return }
        stop()
        synthesizingID = voice.id
        task = Task { [weak self] in
            let request = SynthesisRequest(text: Self.sampleText, voice: voice)
            var synth = services.audioStore.loadAllowingLegacyModel(request)?.audio
            if synth == nil {
                guard await services.isSubscribed() else { self?.synthesizingID = nil; return }
                guard !Task.isCancelled else { return }
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

private final class DemoDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { onFinish?() }
    }
}
