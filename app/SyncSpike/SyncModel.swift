import Foundation
import AVFAudio
import QuartzCore
import ReaderCore

/// Drives the sync overlay: loads a captured fixture (text + alignment + mp3),
/// tokenizes with MeCab, folds char timings into token spans, plays the audio,
/// and advances the highlighted token each display frame via CADisplayLink.
@MainActor
@Observable
final class SyncModel {
    private(set) var fixtureNames: [String] = []
    var selected: String = ""

    private(set) var spans: [TokenSpan] = []
    private(set) var activeIndex: Int?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false

    private let tokenizer = try? MeCabTokenizer()
    private var player: AVAudioPlayer?
    private let link = DisplayLinkProxy()

    private struct FixtureData: Decodable {
        let text: String
        let alignment: Alignment
    }

    func bootstrap() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        link.onTick = { [weak self] in MainActor.assumeIsolated { self?.tick() } }

        fixtureNames = discoverFixtures()
        let env = ProcessInfo.processInfo.environment
        selected = env["SYNC_FIXTURE"].flatMap { fixtureNames.contains($0) ? $0 : nil }
            ?? fixtureNames.first ?? ""
        load(selected)
        if let s = env["SYNC_SEEK"], let t = Double(s) { seek(to: t) }
        if env["SYNC_AUTOPLAY"] == "1" { play() }
    }

    /// Render the highlight at a known playhead time without playing — for
    /// deterministic screenshot verification.
    func seek(to t: Double) {
        player?.currentTime = t
        currentTime = t
        activeIndex = indexForTime(t)
    }

    func load(_ name: String) {
        stop()
        spans = []; activeIndex = nil; currentTime = 0; duration = 0
        guard
            let jsonURL = Bundle.main.url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: jsonURL),
            let fx = try? JSONDecoder().decode(FixtureData.self, from: data)
        else { return }

        let tokens = tokenizer?.tokenize(fx.text) ?? []
        spans = CharTokenMapper.map(tokens: tokens, alignment: fx.alignment)

        if let mp3 = Bundle.main.url(forResource: name, withExtension: "mp3"),
           let p = try? AVAudioPlayer(contentsOf: mp3) {
            p.prepareToPlay()
            player = p
            duration = p.duration
        }
    }

    // MARK: - Transport

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if currentTime >= duration { player.currentTime = 0 }
        player.play()
        isPlaying = true
        link.start()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        link.stop()
    }

    func restart() {
        player?.currentTime = 0
        currentTime = 0
        activeIndex = nil
        play()
    }

    private func stop() {
        player?.stop()
        isPlaying = false
        link.stop()
    }

    // MARK: - Per-frame update

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        activeIndex = indexForTime(currentTime)
        if !player.isPlaying {
            isPlaying = false
            link.stop()
        }
    }

    /// Rightmost token whose start ≤ t (binary search). Gives a continuous
    /// highlight that advances and never flickers between tokens.
    private func indexForTime(_ t: Double) -> Int? {
        guard !spans.isEmpty else { return nil }
        var lo = 0, hi = spans.count - 1, ans = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if spans[mid].start <= t { ans = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return ans >= 0 ? ans : nil
    }

    private func discoverFixtures() -> [String] {
        let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        return urls
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { Bundle.main.url(forResource: $0, withExtension: "mp3") != nil }
            .sorted()
    }
}

/// CADisplayLink needs an `@objc` target; this keeps `SyncModel` a clean
/// `@Observable`. The link is added to the main run loop, so ticks fire on the
/// main thread (hence `MainActor.assumeIsolated` at the call site is valid).
private final class DisplayLinkProxy: NSObject {
    var onTick: (() -> Void)?
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() { onTick?() }
}
