import SwiftUI
import AVFAudio
import QuartzCore
import ReaderCore
import struct ReaderCore.Document   // disambiguate from SwiftUI.Document

/// Drives one chapter: load-or-synthesize audio + alignment, tokenize the exact
/// text the alignment indexes, fold char timings into token spans, play the mp3,
/// and advance the active token each display frame from the real playhead. The
/// highlight visual is the design's; the timing is the proven sync pipeline.
@MainActor
@Observable
final class ReaderModel {
    enum LoadState: Equatable { case loading, ready, failed(String) }
    /// Audio is the only gated feature, with a lifecycle independent of the
    /// always-available reading surface: `.locked` = not subscribed (show the
    /// membership pill), `.idle` = subscribed but not yet generated (Play to
    /// synthesize), `.synthesizing` = generating, `.ready` = player + timed spans
    /// loaded, `.notGenerated`/`.failed` = synth had no offline audio / errored.
    enum AudioState: Equatable { case locked, idle, synthesizing, ready, notGenerated, failed(String) }

    let document: Document
    private let services: AppServices

    private(set) var loadState: LoadState = .loading
    private(set) var audioState: AudioState = .locked
    private(set) var timeline = SpanTimeline([])
    /// Bumped whenever `timeline` is replaced. The reading surface compares this
    /// cheap integer to decide whether to relayout, instead of re-hashing every
    /// token's strings on each highlight frame (~60×/sec). See `setTimeline`.
    private(set) var structureVersion = 0
    private(set) var activeIndex: Int?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// Estimated synthesis progress (0…1) while `audioState == .synthesizing`.
    /// Purely cosmetic: the Worker buffers the whole response, so no real signal
    /// exists — eased against a char-count time estimate, snapped to 1 on success.
    private(set) var synthesisProgress: Double = 0

    var speed: Double = 1.0
    var chromeVisible = true

    // Chapters (multi-chapter imports; single-chapter docs just read .first)
    private(set) var chapterIndex = 0
    var chaptersVisible = false

    // Dictionary sheet
    private(set) var entry: DictionaryEntry?
    var sheetVisible = false

    private var player: AVAudioPlayer?
    /// On-device speech for the tap-to-define pronunciation button. Free and
    /// ungated — distinct from the subscription-gated chapter narration.
    private let speech = AVSpeechSynthesizer()
    /// Lock-screen / Control Center transport; lifecycle mirrors the audio session.
    private let nowPlaying = NowPlayingController()
    private let link = DisplayLinkProxy()
    /// The in-flight synthesis+play task, if any. Held so leaving the reader can
    /// cancel it — otherwise an orphaned synthesis finishes into a dismissed model
    /// and starts playback (and a reopen would run a second, duplicate paid synth).
    private var playbackTask: Task<Void, Never>?
    /// The 10 Hz ticker behind `synthesisProgress`; dies with the synthesis it dresses.
    private var synthesisProgressTask: Task<Void, Never>?
    /// Bridges `AVAudioPlayer`'s completion callback (which fires even backgrounded,
    /// when the display link is dead) back to the model.
    private var audioDelegate: PlayerDelegate?
    /// Tokens for the audio-session interruption + route-change observers, removed
    /// on deinit. `nonisolated(unsafe)`: written once in `init`, read once in the
    /// nonisolated `deinit` — no concurrent access.
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    /// Whether the user was actually playing when an interruption began — so
    /// `.ended` + `.shouldResume` never un-pauses a manually paused reader.
    private var wasPlayingBeforeInterruption = false
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
        // Pause/resume around audio-session interruptions (calls, Siri). Delivered on
        // the main queue; the model is main-actor, so hopping via assumeIsolated is valid.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        // Pause when the output route disappears (headphones out / BT drop) —
        // the notification arrives on a secondary thread; the main queue hops it.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
        // Remote (lock-screen) commands route through the same transport methods
        // as the in-app controls, so Now Playing state stays consistent for free.
        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onTogglePlayPause = { [weak self] in self?.togglePlay() }
        nowPlaying.onSeek = { [weak self] t in self?.seek(to: t) }
        nowPlaying.onNextChapter = { [weak self] in
            guard let self else { return }
            Task { await self.remoteOpenChapter(1) }
        }
        nowPlaying.onPreviousChapter = { [weak self] in
            guard let self else { return }
            Task { await self.remoteOpenChapter(-1) }
        }
    }

    /// Backstop teardown for the display link. ReaderModel sits OUTSIDE the
    /// proxy↔CADisplayLink retain cycle (the proxy holds the model weakly), so
    /// this deinit can run and break the cycle even if `onDisappear` is missed.
    deinit {
        link.stop()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
    }

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
    /// Display title for the current chapter: the imported TOC title, else the
    /// localized ordinal fallback (chrome; the real title is reader content).
    var chapterTitle: String { currentChapter?.title ?? L10n.chapterNumber(chapterIndex + 1) }
    var canGoToPreviousChapter: Bool { chapterIndex > 0 }
    var canGoToNextChapter: Bool { chapterIndex < chapterCount - 1 }

    // MARK: - Load

    func load() async {
        loadGeneration &+= 1
        let gen = loadGeneration
        loadState = .loading
        link.onTick = { [weak self] in MainActor.assumeIsolated { self?.tick() } }

        // Render the text for EVERYONE: tokenize the chapter and show it with
        // furigana + tap-to-define, no audio required. Speech generation is the only
        // gated feature, so the reading surface is always available — even offline /
        // unsubscribed. The word-synced highlight simply stays absent until audio is
        // loaded. Tokenization (and the first-use IPADic load) runs on the worker
        // actor so the route transition never janks the main thread.
        let text = currentChapter?.text ?? ""
        let tokens = await services.tokenizerWorker.tokenize(text)
        guard gen == loadGeneration, !Task.isCancelled else { return }
        guard let tokens else {
            loadState = .failed(L10n.readerFailedTokenizer); return
        }
        setTimeline(SpanTimeline(untimedTokens: tokens))
        loadState = .ready

        // Audio gate: require `reader Pro` (checked locally) before generating
        // speech, so a non-subscriber never hits the paid Worker. No-op ungate when
        // RevenueCat isn't configured (dev/offline). Synthesis is deferred to Play.
        let subscribed = await services.isSubscribed()
        guard gen == loadGeneration, !Task.isCancelled else { return }
        audioState = subscribed ? .idle : .locked

        // Already-paid local audio: load it eagerly (no network) so a re-read gets
        // the word-synced highlight immediately and resumes where it stopped.
        if subscribed {
            let key = SynthesisRequest(text: text, voice: services.narrationVoice).cacheKey
            if let cached = services.audioStore.load(key),
               await buildPlayback(from: cached, gen: gen) {
                audioState = .ready
            } else if services.synthesis.isSynthesizing(key) {
                // A synthesis this user already started (and is paying for) is
                // still running — the user left mid-generation and came back.
                // Re-attach: show progress and play when it lands, exactly as if
                // they had never left.
                startAudio()
            }
        }
    }

    /// Launch synthesis+play as the model-held `playbackTask` so leaving the reader
    /// (`stop()`) can cancel the *awaiting/playing* side — preventing an orphaned
    /// completion from starting playback after teardown. The network request itself
    /// belongs to `SynthesisCoordinator` and survives this task's cancellation; a
    /// reopen re-attaches to it instead of running a duplicate paid synthesis.
    func startAudio() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in await self?.requestAudioAndPlay() }
    }

    /// Generate (or load) the chapter's speech, then start playback. Invoked by the
    /// Play control when audio isn't loaded yet (`.idle`) or a previous attempt
    /// failed. The only path that triggers synthesis — reading never does.
    func requestAudioAndPlay() async {
        switch audioState {
        case .ready: play(); return
        case .synthesizing, .locked: return
        case .idle, .notGenerated, .failed: break
        }
        synthesisProgress = 0   // a cache hit never animates; a miss restarts from empty
        audioState = .synthesizing
        // The progress bar is the only sign a paid request is running — pin the
        // chrome so a stray background tap can't hide it (toggleChrome also
        // refuses while synthesizing).
        chromeVisible = true
        if await ensureAudio() { play() }
    }

    /// Explicit cancel from the synthesizing pill — the one deliberate way to
    /// abandon a paid request. The thrown cancellation lands in `ensureAudio`'s
    /// catch, which returns the pill to `.idle`.
    func cancelSynthesis() {
        guard audioState == .synthesizing else { return }
        services.synthesis.cancel(
            SynthesisRequest(text: currentChapter?.text ?? "",
                             voice: services.narrationVoice).cacheKey)
    }

    /// Wall-clock estimate for synthesizing `charCount` chars through the Worker,
    /// which buffers the whole response (~generation-time latency). Tunable.
    private static func estimatedSynthesisSeconds(_ charCount: Int) -> Double {
        8 + Double(charCount) / 90
    }

    /// Drive the cosmetic progress toward ~0.92 on an exponential ease: fast early,
    /// ~0.84 around the estimate, and still creeping if synthesis runs long — the
    /// bar never freezes, and never claims completion it can't know.
    private func beginSynthesisProgress(charCount: Int) {
        synthesisProgressTask?.cancel()
        synthesisProgress = 0
        let estimate = Self.estimatedSynthesisSeconds(charCount)
        let start = Date()
        synthesisProgressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, !Task.isCancelled else { return }
                let t = Date().timeIntervalSince(start)
                self.synthesisProgress = 0.92 * (1 - exp(-t / (estimate / 2.5)))
            }
        }
    }

    /// Stop the cosmetic progress: full bar on success (shown briefly while
    /// playback is built, just before `.ready`), reset on failure.
    private func endSynthesisProgress(success: Bool) {
        synthesisProgressTask?.cancel()
        synthesisProgressTask = nil
        synthesisProgress = success ? 1 : 0
    }

    /// Cache-or-synthesize the chapter audio and build playback. Sets `audioState`
    /// to the outcome and returns whether playback is ready. The single
    /// `tts.synthesize` call site.
    private func ensureAudio() async -> Bool {
        if player != nil { audioState = .ready; return true }
        let gen = loadGeneration
        let request = SynthesisRequest(text: currentChapter?.text ?? "",
                                       voice: services.narrationVoice)
        let key = request.cacheKey

        let synth: SynthesizedAudio
        if let cached = services.audioStore.load(key) {
            synth = cached
        } else {
            do {
                beginSynthesisProgress(charCount: request.text.count)
                // The coordinator owns the request (and saves the paid result to
                // the cache the moment it returns): leaving the reader doesn't
                // cancel it, and a re-entry awaits this same task instead of
                // re-billing. Only cancelSynthesis() abandons it.
                synth = try await services.synthesis.task(for: request).value
                endSynthesisProgress(success: true)
            } catch is CancellationError {
                // Explicit user cancel from the synthesizing pill — back to the
                // Play affordance, no error banner.
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .idle }
                return false
            } catch let e as URLError where e.code == .cancelled {
                // The same explicit cancel, surfaced as URLSession's cancellation.
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .idle }
                return false
            } catch is FixtureTTSService.FixtureError {
                // No offline audio for this text — the genuine "not generated" case.
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .notGenerated }
                return false
            } catch WorkerTTSService.WorkerError.subscriptionRequired {
                // Entitlement lapsed (server-side 403) — re-lock and show the pill.
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .locked }
                return false
            } catch is URLError {
                // Transport failure (DNS, offline, timeout) — a human message,
                // not Apple's raw NSURLError text. HTTP statuses never land
                // here; WorkerTTSService maps them to WorkerError first.
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .failed(L10n.readerFailedNetwork) }
                return false
            } catch {
                // Real failure (Worker auth, decode) — surface it, don't
                // disguise it as "not generated".
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .failed(error.localizedDescription) }
                return false
            }
        }

        guard await buildPlayback(from: synth, gen: gen) else {
            endSynthesisProgress(success: false)
            if gen == loadGeneration { audioState = .failed(L10n.readerFailedAudio) }
            return false
        }
        audioState = .ready
        return true
    }

    /// Build the player + timed spans from synthesized audio (cached or freshly
    /// generated). Re-tokenizes the synthesized text (the exact text the alignment
    /// indexes) and folds the char timings into spans so the highlight tracks the
    /// real playhead, then resumes the saved position. Returns false if superseded
    /// by a newer load() / torn down, or the audio can't be decoded.
    private func buildPlayback(from synth: SynthesizedAudio, gen: Int) async -> Bool {
        guard gen == loadGeneration, !Task.isCancelled else { return false }

        // Tokenize the EXACT text the alignment indexes (single source of truth) and
        // fold the char timings onto the tokens for the moving highlight.
        guard let tokens = await services.tokenizerWorker.tokenize(synth.text),
              gen == loadGeneration, !Task.isCancelled else { return false }
        setTimeline(SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: synth.alignment)))

        // The audio SESSION is activated in play() (first real playback), not here —
        // merely opening a chapter with cached audio must not duck other apps' audio.
        do {
            let p = try AVAudioPlayer(data: synth.audio)
            p.enableRate = true
            p.rate = Float(speed)
            p.prepareToPlay()
            // Delegate owns natural-finish handling; it fires even backgrounded, when
            // the CADisplayLink (a foreground-only clock) is paused.
            let d = PlayerDelegate()
            d.onFinish = { [weak self] in self?.handlePlaybackFinished() }
            p.delegate = d
            audioDelegate = d
            player = p
            duration = p.duration
        } catch {
            return false
        }

        // Resume where the last session left off (only for the saved chapter, and
        // unless it was effectively finished).
        let resume = document.progress.time
        if chapterIndex == document.progress.chapterIndex, resume > 0, resume < duration - 0.5 {
            player?.currentTime = resume
            currentTime = resume
            activeIndex = timeline.index(at: resume)
        }
        return true
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        activateSession()
        if currentTime >= duration { player.currentTime = 0 }
        player.enableRate = true
        player.rate = Float(speed)
        player.play()
        isPlaying = true
        link.start()
        nowPlaying.setPlayback(elapsed: player.currentTime, rate: speed)
    }

    /// Activate the playback audio session at the first real playback — deferred out
    /// of `buildPlayback` so opening a cached chapter doesn't interrupt other audio.
    /// Now Playing rides along: the lock-screen widget exists exactly while the
    /// session does.
    private func activateSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        nowPlaying.activate()
        nowPlaying.setMetadata(bookTitle: document.title, chapterTitle: chapterTitle,
                               chapterIndex: chapterIndex, chapterCount: chapterCount,
                               duration: duration)
        nowPlaying.setChapterBounds(hasPrevious: canGoToPreviousChapter,
                                    hasNext: canGoToNextChapter)
    }

    /// Release the session so other apps' audio can resume after we stop.
    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        link.stop()
        persistProgress()
        nowPlaying.setPlayback(elapsed: player?.currentTime ?? currentTime, rate: 0)
    }

    func setSpeed(_ v: Double) {
        speed = v
        player?.enableRate = true
        player?.rate = Float(v)
        nowPlaying.setPlayback(elapsed: player?.currentTime ?? currentTime,
                               rate: isPlaying ? v : 0)
    }

    /// Move the playhead (scrubbing / VoiceOver adjust). Works while playing or
    /// paused; the highlight jumps to the new position immediately.
    func seek(to t: Double) {
        guard let player, duration > 0 else { return }
        let clamped = min(max(0, t), duration)
        player.currentTime = clamped
        currentTime = clamped
        activeIndex = timeline.index(at: clamped)
        nowPlaying.setPlayback(elapsed: clamped, rate: isPlaying ? speed : 0)
    }

    /// Tap-empty-space chrome toggle. Refused while synthesizing: the progress
    /// bar is the only feedback a paid generation is running, and hiding it
    /// makes the app read as hung.
    func toggleChrome() {
        guard audioState != .synthesizing else { return }
        chromeVisible.toggle()
    }

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

    /// Unattended chapter switch (lock-screen skip, or the natural-finish
    /// auto-advance): switch chapters, then resume playback only if the new
    /// chapter's audio is already local (cache hit in `load()`). Never triggers
    /// a paid synthesis — synthesis stays an explicit in-app Play action, so an
    /// uncached skip simply ends the session (openChapter's `stop()` already
    /// cleared the widget).
    private func remoteOpenChapter(_ delta: Int) async {
        await openChapter(chapterIndex + delta)
        if audioState == .ready { play() }
    }

    func stop() {
        saveProgressOnLeave()   // capture the playhead (or chapter) before tearing down
        // Supersede the in-flight playback task: bump the generation so a completion
        // that arrives after teardown fails its `gen == loadGeneration` guard and
        // never starts playback. The synthesis REQUEST itself is not cancelled —
        // it's the coordinator's (the paid result still lands in the cache, and a
        // reopen re-attaches to the same task instead of re-billing).
        loadGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        synthesisProgressTask?.cancel()
        synthesisProgressTask = nil
        player?.stop()
        player = nil            // don't let a stale player replay under a new chapter
        duration = 0
        isPlaying = false
        nowPlaying.deactivate()
        deactivateSession()
        link.stop()
    }

    // MARK: - Progress persistence

    /// Save reading position on leave / background: the audio playhead when audio is
    /// loaded, else at least the current chapter so free-tier (no-audio) reading
    /// resumes on the right chapter. The two paths guard each other, so calling both
    /// is safe — only the applicable one writes.
    func saveProgressOnLeave() {
        persistProgress()
        persistChapterPosition()
    }

    /// Free reading surface (no generated audio): persist the current chapter so a
    /// reopen resumes here. Only fires when the user actually changed chapters and
    /// audio isn't the source of truth — so it never overwrites a saved playhead
    /// within the same chapter with a zero.
    private func persistChapterPosition() {
        guard audioState != .ready,
              document.chapters.indices.contains(chapterIndex),
              chapterIndex != document.progress.chapterIndex else { return }
        var doc = document
        doc.progress = ReadingProgress(chapterIndex: chapterIndex, time: 0,
                                       fraction: Double(chapterIndex) / Double(max(1, chapterCount)))
        services.library.save(doc)
    }

    /// Write the playhead back to the library so the row reflects real reading and
    /// the next open resumes here. Called on pause / leave / completion /
    /// backgrounding — never per frame. No-op until the chapter is loaded, so a
    /// failed or not-generated open never clobbers saved progress with zeros. The
    /// keep-or-skip decision lives in `ReadingProgressResolver` (tested): a zero
    /// playhead from a never-played open is skipped, while a `completed` chapter is
    /// always written (its `AVAudioPlayer` playhead has already reset to 0).
    func persistProgress(completed: Bool = false) {
        guard audioState == .ready, duration > 0 else { return }
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
        guard let player, player.isPlaying else {
            // Not playing: either paused (link already stopped) or finished. Natural
            // finish is owned by `handlePlaybackFinished` via the AVAudioPlayerDelegate
            // (which fires even backgrounded, where this display-link clock is dead),
            // so don't persist here — just stop the foreground clock.
            link.stop()
            return
        }
        currentTime = player.currentTime
        activeIndex = timeline.index(at: currentTime)
    }

    /// Natural end of the chapter — routed through the AVAudioPlayerDelegate so it
    /// also runs while backgrounded (screen locked). Marks the chapter complete
    /// (読了), then continues into the next chapter IF its narration is already
    /// local — an unattended finish must never trigger a paid synthesis (the same
    /// rule as the lock-screen skip). Without a cached continuation the lock-screen
    /// widget is kept (paused at the end) so a pocketed phone still has transport;
    /// only the audio session is released.
    private func handlePlaybackFinished() {
        isPlaying = false
        link.stop()
        currentTime = duration
        activeIndex = timeline.index(at: duration)
        persistProgress(completed: true)
        if canGoToNextChapter, nextChapterAudioCached {
            // The assertion covers the tokenize+load gap between players so a
            // locked phone isn't suspended mid-advance (no audio is playing yet).
            let assertion = BackgroundAssertion(name: "chapter-advance")
            Task {
                await self.remoteOpenChapter(1)
                assertion.end()
            }
            return
        }
        nowPlaying.setPlayback(elapsed: duration, rate: 0)
        deactivateSession()
    }

    /// Whether the NEXT chapter's narration is already in the local cache under
    /// the current voice — the auto-advance gate: cached audio is free to play.
    private var nextChapterAudioCached: Bool {
        let next = chapterIndex + 1
        guard document.chapters.indices.contains(next) else { return false }
        return services.audioStore.has(
            SynthesisRequest(text: document.chapters[next].text,
                             voice: services.narrationVoice).cacheKey)
    }

    /// Audio-session interruption (call, Siri, another app): pause on `.began`, and
    /// resume on `.ended` when the system says we may — but only if the USER was
    /// playing when the interruption hit. Without that memory, a manually paused
    /// reader would spring back to life after a phone call. Works while backgrounded.
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            if isPlaying { pause() }
        case .ended:
            let resume = wasPlayingBeforeInterruption
            wasPlayingBeforeInterruption = false
            if resume,
               let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume),
               player != nil {
                play()
            }
        @unknown default:
            break
        }
    }

    /// The playback route lost its output device (headphones unplugged, BT
    /// dropped): pause, per platform convention — never blare from the open
    /// speaker. Other reasons (a new device attached) don't pause.
    private func handleRouteChange(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable,
              isPlaying else { return }
        pause()
    }

    // MARK: - Tap to define

    func tapToken(_ i: Int) {
        guard let span = timeline[i], hasWordChar(span.surface) else { return }
        let lemma = span.dictionaryForm ?? span.surface
        entry = services.dictionary.lookup(dictionaryForm: lemma, reading: span.reading)
            ?? DictionaryEntry(id: -1, word: span.surface, reading: span.reading ?? "",
                               senses: [Sense(glosses: [L10n.dictNotFound], partsOfSpeech: ["—"])])
        sheetVisible = true
    }

    /// Speak the current headword with the built-in Japanese voice. Prefers the
    /// reading (unambiguous kana) over the surface word to avoid homograph
    /// mispronunciation.
    func pronounceEntry() {
        guard let entry else { return }
        let text = entry.reading.isEmpty ? entry.word : entry.reading
        guard !text.isEmpty else { return }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        speech.speak(utterance)
    }

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

/// `AVAudioPlayer` needs an NSObject delegate; this keeps `ReaderModel` a clean
/// `@Observable` and forwards the finish callback. The callback is delivered on the
/// thread that started playback (the main run loop here), so hopping onto the main
/// actor via `assumeIsolated` is valid — mirroring `DisplayLinkProxy`.
private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { onFinish?() }
    }
}
