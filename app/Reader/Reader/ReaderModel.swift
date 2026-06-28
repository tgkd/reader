import SwiftUI
import AVFAudio
import QuartzCore
import ReaderCore

/// Drives one chapter: load-or-synthesize audio + alignment, tokenize the exact
/// text the alignment indexes, fold char timings into token spans, play the mp3,
/// and advance the active token each display frame from the real playhead. The
/// highlight visual is the design's; the timing is the proven sync pipeline.
@MainActor
@Observable
final class ReaderModel {
    enum LoadState: Equatable { case loading, ready, notGenerated, failed(String) }
    enum Orientation { case tate, yoko }

    let document: Document
    private let services: AppServices

    private(set) var loadState: LoadState = .loading
    private(set) var timeline = SpanTimeline([])
    /// Bumped whenever `timeline` is replaced. The reading surface compares this
    /// cheap integer to decide whether to relayout, instead of re-hashing every
    /// token's strings on each highlight frame (~60×/sec). See `setTimeline`.
    private(set) var structureVersion = 0
    private(set) var activeIndex: Int?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false

    var speed: Double = 1.0
    var orientation: Orientation = .tate
    var chromeVisible = true

    // Chapters (multi-chapter imports; single-chapter docs just read .first)
    private(set) var chapterIndex = 0
    var chaptersVisible = false

    // Dictionary sheet
    private(set) var entry: DictionaryEntry?
    var sheetVisible = false
    var saved = false

    private var player: AVAudioPlayer?
    private let link = DisplayLinkProxy()
    private var isSwitchingChapter = false
    /// Bumped at the top of every `load()`. A load that finds itself superseded
    /// (a newer chapter switch, or the view torn down) after its `await` bails
    /// before touching the shared player/timeline/loadState — so two overlapping
    /// loads can't mis-pair audio with text.
    private var loadGeneration = 0

    init(document: Document, services: AppServices) {
        self.document = document
        self.services = services
        let saved = document.progress.chapterIndex
        chapterIndex = document.chapters.indices.contains(saved) ? saved : 0
        #if DEBUG
        if ProcessInfo.processInfo.environment["READER_CHAPTERS"] == "1" { chaptersVisible = true }
        #endif
    }

    /// Backstop teardown for the display link. ReaderModel sits OUTSIDE the
    /// proxy↔CADisplayLink retain cycle (the proxy holds the model weakly), so
    /// this deinit can run and break the cycle even if `onDisappear` is missed.
    deinit { link.stop() }

    var spans: [TokenSpan] { timeline.spans }
    var progressFraction: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    /// The single mutation point for `timeline` — keeps `structureVersion` in lock
    /// step so the surface relayouts exactly when the token list actually changes.
    private func setTimeline(_ t: SpanTimeline) {
        timeline = t
        structureVersion &+= 1
    }

    var currentChapter: Chapter? {
        document.chapters.indices.contains(chapterIndex) ? document.chapters[chapterIndex] : document.chapters.first
    }
    var chapterCount: Int { document.chapters.count }
    var hasChapters: Bool { chapterCount > 1 }

    // MARK: - Load

    func load() async {
        loadGeneration &+= 1
        let gen = loadGeneration
        loadState = .loading
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        link.onTick = { [weak self] in MainActor.assumeIsolated { self?.tick() } }

        guard let tokenizer = services.tokenizer else {
            loadState = .failed("Tokenizer unavailable"); return
        }
        let text = currentChapter?.text ?? ""
        let request = SynthesisRequest(text: text)
        let key = request.cacheKey

        let synth: SynthesizedAudio
        if let cached = services.audioStore.load(key) {
            synth = cached
        } else {
            do {
                synth = try await services.tts.synthesize(request)
                // Cache the (network-paid) result before any bail-out: the disk
                // write is cheap, local, and the valuable artifact — it must not
                // be lost just because this load was superseded or dismissed.
                services.audioStore.save(synth, for: key)
            } catch is FixtureTTSService.FixtureError {
                // No offline audio for this text — the genuine "not generated" case.
                if gen == loadGeneration { loadState = .notGenerated }
                return
            } catch {
                // Real failure (Worker auth/network, decode) — surface it, don't
                // disguise it as "not generated".
                if gen == loadGeneration { loadState = .failed(error.localizedDescription) }
                return
            }
        }

        // Superseded by a newer load() (chapter switch) or the view torn down
        // while we awaited synthesis? Stop before mutating the shared player /
        // timeline / loadState, so overlapping loads can't mis-pair audio + text.
        guard gen == loadGeneration, !Task.isCancelled else { return }

        // Tokenize the EXACT text the alignment indexes (single source of truth).
        let tokens = tokenizer.tokenize(synth.text)
        setTimeline(SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: synth.alignment)))

        do {
            let p = try AVAudioPlayer(data: synth.audio)
            p.enableRate = true
            p.rate = Float(speed)
            p.prepareToPlay()
            player = p
            duration = p.duration
        } catch {
            loadState = .failed("Audio failed to load"); return
        }

        // Resume where the last session left off (only for the saved chapter, and
        // unless it was effectively finished).
        let resume = document.progress.time
        if chapterIndex == document.progress.chapterIndex, resume > 0, resume < duration - 0.5 {
            player?.currentTime = resume
            currentTime = resume
            activeIndex = timeline.index(at: resume)
        }

        loadState = .ready
        #if DEBUG
        applyDebugHooks()
        #endif
    }

    #if DEBUG
    /// Launch hooks for deterministic screenshots (pass via SIMCTL_CHILD_*):
    ///   READER_ORI=tate|yoko, READER_SEEK=<seconds> (render highlight paused),
    ///   READER_AUTOPLAY=1, READER_SHEET=<token index>.
    private func applyDebugHooks() {
        let env = ProcessInfo.processInfo.environment
        if let o = env["READER_ORI"] { orientation = (o == "yoko") ? .yoko : .tate }
        if let s = env["READER_SEEK"], let t = Double(s) {
            player?.currentTime = t
            currentTime = t
            activeIndex = timeline.index(at: t)
        }
        if env["READER_AUTOPLAY"] == "1" { play() }
        if let raw = env["READER_SHEET"], let i = Int(raw) { tapToken(i) }
    }
    #endif

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        if currentTime >= duration { player.currentTime = 0 }
        player.enableRate = true
        player.rate = Float(speed)
        player.play()
        isPlaying = true
        link.start()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        link.stop()
        persistProgress()
    }

    func setSpeed(_ v: Double) {
        speed = v
        player?.enableRate = true
        player?.rate = Float(v)
    }

    /// Move the playhead (scrubbing / VoiceOver adjust). Works while playing or
    /// paused; the highlight jumps to the new position immediately.
    func seek(to t: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(0, t), duration)
        player.currentTime = clamped
        currentTime = clamped
        activeIndex = timeline.index(at: clamped)
    }

    func toggleOrientation() { orientation = orientation == .tate ? .yoko : .tate }
    func toggleChrome() { chromeVisible.toggle() }

    /// Switch to another chapter: save the current spot, tear down, reload. The
    /// new chapter starts at the top (only the saved resume chapter restores time).
    func openChapter(_ i: Int) async {
        chaptersVisible = false
        // Reentrancy guard: a fast double-tap must not start two overlapping loads
        // that race the shared player/timeline and mis-pair audio with text.
        guard !isSwitchingChapter, document.chapters.indices.contains(i), i != chapterIndex else { return }
        isSwitchingChapter = true
        stop()                       // persists current chapter's progress + tears down audio
        chapterIndex = i
        currentTime = 0
        activeIndex = nil
        duration = 0
        setTimeline(SpanTimeline([]))
        await load()
        isSwitchingChapter = false
    }

    func stop() {
        persistProgress()       // capture the playhead before tearing down
        player?.stop()
        isPlaying = false
        link.stop()
    }

    // MARK: - Progress persistence

    /// Write the playhead back to the library so the row reflects real reading and
    /// the next open resumes here. Called on pause / leave / completion /
    /// backgrounding — never per frame. No-op until the chapter is loaded, so a
    /// failed or not-generated open never clobbers saved progress with zeros. The
    /// keep-or-skip decision lives in `ReadingProgressResolver` (tested): a zero
    /// playhead from a never-played open is skipped, while a `completed` chapter is
    /// always written (its `AVAudioPlayer` playhead has already reset to 0).
    func persistProgress(completed: Bool = false) {
        guard loadState == .ready, duration > 0 else { return }
        let stop: PlaybackStop = completed
            ? .completed
            : .interrupted(time: player?.currentTime ?? currentTime)
        guard let progress = ReadingProgressResolver.resolve(stop, duration: duration,
                                                             chapterIndex: chapterIndex,
                                                             chapterCount: chapterCount)
        else { return }
        currentTime = progress.time
        var doc = document
        doc.progress = progress
        services.library.save(doc)
    }

    private func tick() {
        guard let player else { return }
        if !player.isPlaying {
            // Playback stopped. `AVAudioPlayer` zeroes `currentTime` on a *natural*
            // finish, so detect "reached the end" from the last playhead we recorded
            // (≈duration) rather than the reset value — else a finished chapter
            // persists as 0 and never shows 読了. A stop short of the end (e.g. an
            // audio-session interruption) keeps its real position.
            isPlaying = false
            link.stop()
            let reachedEnd = currentTime >= duration - 0.5
            if reachedEnd {
                currentTime = duration
                activeIndex = timeline.index(at: duration)
            }
            persistProgress(completed: reachedEnd)
            return
        }
        currentTime = player.currentTime
        activeIndex = timeline.index(at: currentTime)
    }

    // MARK: - Tap to define

    func tapToken(_ i: Int) {
        guard let span = timeline[i], hasWordChar(span.surface) else { return }
        let lemma = span.dictionaryForm ?? span.surface
        entry = services.dictionary.lookup(dictionaryForm: lemma, reading: span.reading)
            ?? DictionaryEntry(id: -1, word: span.surface, reading: span.reading ?? "",
                               senses: [Sense(glosses: [L10n.dictNotFound], partsOfSpeech: ["—"])])
        saved = false
        sheetVisible = true
    }

    func toggleSaved() { saved.toggle() }

    // MARK: - Helpers

    func timeLabel(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    /// A token is tappable if it contains a kana/kanji/letter/digit — i.e. not
    /// pure punctuation (。、「」), which the design also skips.
    private func hasWordChar(_ s: String) -> Bool {
        s.unicodeScalars.contains { sc in
            let v = sc.value
            return (0x3041...0x3096).contains(v)   // hiragana
                || (0x30A1...0x30FA).contains(v)   // katakana
                || (0x4E00...0x9FFF).contains(v)   // CJK kanji
                || (0x0030...0x0039).contains(v)   // digit
                || (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) // latin
        }
    }
}

/// CADisplayLink needs an `@objc` target; this keeps `ReaderModel` a clean
/// `@Observable`. The link runs on the main run loop, so ticks fire on the main
/// thread (hence `MainActor.assumeIsolated` is valid at the call site).
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
