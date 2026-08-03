import SwiftUI
import AVFoundation   // AVPlayer (progressive playback); AVFAudio alone lacks it
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
    /// Audio GENERATION is the only gated feature, with a lifecycle independent
    /// of the always-available reading surface: `.locked` = not subscribed AND
    /// no cached audio for this chapter (show the membership pill — cached
    /// narration plays regardless of entitlement), `.idle` = subscribed but not
    /// yet generated (Play to synthesize), `.synthesizing` = generating,
    /// `.ready` = player + timed spans loaded, `.notGenerated`/`.failed` =
    /// synth had no offline audio / errored.
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
    /// Synthesis progress (0…1) while `audioState == .synthesizing` — the fraction
    /// of the chapter's characters the stream has delivered. Measured, not eased.
    private(set) var synthesisProgress: Double = 0

    var speed: Double = 1.0
    var chromeVisible = true

    // Chapters (multi-chapter imports; single-chapter docs just read .first)
    private(set) var chapterIndex = 0
    var chaptersVisible = false

    // Dictionary sheet
    private(set) var entry: DictionaryEntry?
    var sheetVisible = false

    /// `AVPlayer`, not `AVAudioPlayer`, because narration is played WHILE it is
    /// still being generated: `AVAudioPlayer(data:)` needs the finished file, which
    /// meant ~200 s of silence for a chapter whose audio starts arriving at ~1.7 s.
    /// Cached chapters go through the same player — their bytes simply all arrive
    /// at once — so there is one set of transport, completion and interruption
    /// behaviours rather than two that must be kept in agreement.
    private var player: AVPlayer?
    /// Backs `player`; retains the audio and serves it to `AVPlayer` on demand.
    private var audioSource: ChapterAudioSource?
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
    /// End-of-item observers. `AVPlayer` reports completion by notification rather
    /// than delegate, but the requirement is unchanged: these fire even while
    /// backgrounded, where the display-link clock is dead.
    private var endObservers: [NSObjectProtocol] = []
    /// Boundary observer that ends a progressively-generated chapter at its REAL end.
    /// Held separately because it is removed through `AVPlayer`, not NotificationCenter.
    private var endOfAudioObserver: Any?
    /// Tokens for the audio-session interruption, route-change and media-reset
    /// observers, removed on deinit. `nonisolated(unsafe)`: written once in `init`,
    /// read once in the nonisolated `deinit` — no concurrent access.
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaResetObserver: NSObjectProtocol?
    /// Whether the user was actually playing when an interruption began — so
    /// `.ended` + `.shouldResume` never un-pauses a manually paused reader.
    private var wasPlayingBeforeInterruption = false
    private var isSwitchingChapter = false
    /// The current chapter's tokens from `load()`'s pass, kept with the exact
    /// (normalized) string they were produced from. `buildPlayback` reuses them when
    /// the synthesized text is that same string, instead of running the tokenizer a
    /// second time over identical input.
    private var chapterTokens: (text: String, tokens: [Token])?
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
        // A media-services reset tears down the audio server: the session we activated
        // no longer exists, so drop the flag and let the next `play()` rebuild the
        // category + activation from scratch.
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionIsActive = false }
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
        if let mediaResetObserver { NotificationCenter.default.removeObserver(mediaResetObserver) }
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
        let tokens = await tokenizeWithSourceReadings(text)
        guard gen == loadGeneration, !Task.isCancelled else { return }
        guard let tokens else {
            loadState = .failed(L10n.readerFailedTokenizer); return
        }
        // `MeCabTokenizer` NFKC-normalizes its input, so these tokens ARE the tokens of
        // `Normalize.nfkc(text)` — the string TTS is asked to speak. Keep them so the
        // audio path can fold char timings onto this same pass.
        chapterTokens = (Normalize.nfkc(text), tokens)
        setTimeline(SpanTimeline(untimedTokens: tokens))
        loadState = .ready

        // Already-paid local audio plays for EVERYONE — the subscription gates
        // GENERATION only (decision 2026-07-22): cached playback has no marginal
        // service cost, and a lapsed subscriber keeps what they paid for. Probe
        // the cache first; the entitlement check runs only on a miss, so a cached
        // re-read never depends on a RevenueCat lookup (offline-proof).
        // The probe accepts audio made under an EARLIER DEFAULT MODEL too: the model is
        // in `ContentKey`, so a default change would otherwise make every chapter this
        // user already paid for look uncached — locked for a lapsed subscriber, and
        // silently re-billed for an active one (`SynthesisModel.previousDefaults`).
        let request = SynthesisRequest(text: text, voice: services.narrationVoice)
        let key = request.cacheKey
        if let (cachedKey, cached) = services.audioStore.loadAllowingLegacyModel(request) {
            switch await buildPlayback(from: cached, gen: gen) {
            case .ready:
                audioState = .ready
                return
            case .undecodable:
                // Corrupt entry (valid sidecar, undecodable mp3): evict it so
                // the next Play regenerates instead of re-failing forever.
                services.audioStore.remove(cachedKey)
            case .aborted:
                return
            }
        }

        // Cache miss: NEW synthesis is the gated feature — require `reader Pro`
        // (checked locally) so a non-subscriber never hits the paid Worker. No-op
        // ungate when RevenueCat isn't configured (dev/offline). Synthesis is
        // deferred to Play.
        let subscribed = await services.isSubscribed()
        guard gen == loadGeneration, !Task.isCancelled else { return }
        audioState = subscribed ? .idle : .locked
        if subscribed, services.synthesis.isSynthesizing(key) {
            // A synthesis this user already started (and is paying for) is
            // still running — the user left mid-generation and came back.
            // Re-attach: show progress and play when it lands, exactly as if
            // they had never left.
            startAudio()
        }
    }

    /// Tokenize, then let the SOURCE overrule the tokenizer where the book supplied a
    /// reading of its own.
    ///
    /// MeCab is the tokenizer and stays the single segmentation pass — this only
    /// replaces `reading` on tokens a publisher ruby annotation covers exactly, and
    /// leaves `dictionaryForm` alone so tap-to-define still looks up the kanji. It
    /// matters because IPADic does not know proper nouns: 黄前 is おうまえ, not the
    /// きぜん MeCab infers, and 緑輝 is サファイア, which nothing but the book knows.
    private func tokenizeWithSourceReadings(_ text: String) async -> [Token]? {
        guard let tokens = await services.tokenizerWorker.tokenize(text) else { return nil }
        guard let chapter = currentChapter, !chapter.sourceReadings.isEmpty,
              chapter.text == text else { return tokens }
        return SourceReadingOverlay.apply(chapter.sourceReadings, to: tokens, text: text)
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
        // Cancel our own side too: between Play and the request existing there is a
        // suspension (the local entitlement lookup) where the coordinator has nothing
        // to cancel, and without this the tap would be swallowed and the paid request
        // created anyway. `ensureAudio` checks cancellation across that await.
        playbackTask?.cancel()
    }

    /// Reset progress for a new synthesis. There is no ticker any more: the eased
    /// curve existed because the buffered route gave no signal, and `appendStreamed`
    /// now reports characters actually delivered.
    private func beginSynthesisProgress(charCount: Int) {
        synthesisProgress = 0
    }

    /// Full bar on success (shown briefly while playback is built, just before
    /// `.ready`), reset on failure.
    private func endSynthesisProgress(success: Bool) {
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
        // Legacy-model entries count as a hit here too — see `load()`. Spending money
        // on audio the user already bought under the previous default is the failure
        // this prevents; the new default is used only when nothing is cached at all.
        if let cached = services.audioStore.loadAllowingLegacyModel(request)?.audio {
            synth = cached
        } else {
            // A cache miss is the only path that spends money, and this reader's
            // `.idle` may be days old — revalidate the entitlement LOCALLY before
            // the request, so a lapse while the screen stayed open can't reach the
            // paid Worker (its 403 is the backstop, not the gate). A request already
            // in flight is exempt: that is paid work this user started, and refusing
            // to await it would throw the money away. Cached playback is untouched —
            // it returned above, before this check.
            if !services.synthesis.isSynthesizing(key) {
                let subscribed = await services.isSubscribed()
                // The pill's X can be tapped WHILE that lookup is suspended, when the
                // coordinator has no task to cancel yet — so `cancelSynthesis` cancels
                // this task instead, and the cancellation has to land here, before the
                // paid request is created. Same for a chapter switch that superseded us.
                guard gen == loadGeneration, !Task.isCancelled else {
                    if gen == loadGeneration { audioState = .idle }
                    return false
                }
                guard subscribed else {
                    audioState = .locked
                    return false
                }
            }
            do {
                beginSynthesisProgress(charCount: request.text.count)
                // Subscribe BEFORE the request exists: chunks start arriving ~1.7 s
                // in, and a subscription set up after the await would miss the
                // opening of the chapter — the part the listener is waiting on.
                beginProgressivePlayback(key: key, request: request, gen: gen)
                // `finishProgressivePlayback` clears `progressive`, so this only
                // fires on the failure paths — where the listener is mid-chapter
                // with audio that will never be completed.
                defer {
                    services.synthesisStream.unsubscribe(key)
                    if progressive != nil { abortProgressivePlayback() }
                }
                // The coordinator owns the request (and saves the paid result to
                // the cache the moment it returns): leaving the reader doesn't
                // cancel it, and a re-entry awaits this same task instead of
                // re-billing. Only cancelSynthesis() abandons it.
                synth = try await services.synthesis.task(for: request).value
                endSynthesisProgress(success: true)
                // Already playing from the stream: the audio is complete now, so
                // seal the source and swap the estimated duration for the exact
                // one. Building a second player here would restart the chapter.
                if progressive?.isPlaying == true {
                    finishProgressivePlayback(with: synth, gen: gen)
                    return audioState == .ready
                }
                // Never got far enough to start (a very short chapter, or the
                // stream outran nothing) — drop it and build playback normally.
                progressive = nil
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

        switch await buildPlayback(from: synth, gen: gen) {
        case .ready:
            audioState = .ready
            return true
        case .undecodable:
            // Undecodable bytes are worthless whether cached or fresh — the
            // coordinator already saved a fresh result, so without eviction the
            // next Play would replay the same broken entry as a cache hit and
            // fail once more before regenerating. Evict; Play regenerates.
            services.audioStore.remove(key)
            fallthrough
        case .aborted:
            endSynthesisProgress(success: false)
            // A cancel landing while playback is being built is the user's doing, not
            // a failure: return the pill to Play rather than raising an error banner.
            if gen == loadGeneration {
                audioState = Task.isCancelled ? .idle : .failed(L10n.readerFailedAudio)
            }
            return false
        }
    }

    /// Outcome of `buildPlayback` — `.undecodable` means the audio DATA is bad
    /// (evict it if it came from the cache, or every retry replays the same broken
    /// bytes), while `.aborted` means a newer load superseded us / the tokenizer
    /// was unavailable (touch nothing).
    private enum PlaybackBuild { case ready, undecodable, aborted }

    /// Build the player + timed spans from synthesized audio (cached or freshly
    /// generated). Re-tokenizes the synthesized text (the exact text the alignment
    /// indexes) and folds the char timings into spans so the highlight tracks the
    /// real playhead, then resumes the saved position.
    private func buildPlayback(from synth: SynthesizedAudio, gen: Int) async -> PlaybackBuild {
        guard gen == loadGeneration, !Task.isCancelled else { return .aborted }

        // The EXACT text the alignment indexes is the tokenizer's single source of
        // truth. `load()` already tokenized this chapter under the same normalization,
        // so when the synthesized text is that same string those tokens are — by the
        // tokenizer's determinism — what a second pass would return: reuse them and
        // fold the char timings onto them. Anything else (a stale cache entry from
        // edited text) still tokenizes what the alignment actually indexes.
        let tokens: [Token]?
        if let loaded = chapterTokens, loaded.text == synth.text {
            tokens = loaded.tokens
        } else {
            tokens = await tokenizeWithSourceReadings(synth.text)
        }
        guard let tokens, gen == loadGeneration, !Task.isCancelled else { return .aborted }
        setTimeline(SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: synth.alignment)))

        // The audio SESSION is activated in play() (first real playback), not here —
        // merely opening a chapter with cached audio must not duck other apps' audio.
        guard !synth.audio.isEmpty else { return .undecodable }
        let source = ChapterAudioSource(expectedBytes: synth.audio.count)
        source.append(synth.audio)
        source.finish()
        attachPlayer(to: source)
        // Duration comes from the BYTES, not the alignment, and not the player: an
        // asset served through a resource loader reports its duration asynchronously
        // (the scrubber would sit at zero on open), while the alignment is not
        // guaranteed to describe all of the audio.
        //
        // Measured on this book's chapter 5 (851 chars, `eleven_v3`): the alignment
        // ends at 220.00 s and tracks the audio to ±0.1 s the whole way — and then the
        // mp3 keeps going to 227.68 s, four more bursts of speech the API returned no
        // timings for at all. 7.7 s, 3.4% of the chapter, invisible to every check we
        // have: the arrays are parallel, monotonic, and `characters.joined() == text`.
        // Trusting `timeline.duration` there makes the player claim the chapter ends
        // 7.7 s before it does — the scrubber pins at 100% and the remaining readout
        // hits zero while paid narration is still playing.
        //
        // ElevenLabs' output format is `mp3_44100_128`, constant bitrate, and neither
        // the app nor the Worker overrides it, so bytes/16000 is exact rather than an
        // estimate: 3,643,812 bytes → 227.74 s against ffprobe's 227.68 s, 60 ms out
        // over four minutes. `timeline.duration` stays the floor for the degenerate
        // case of an empty or unreadable asset.
        duration = max(timeline.duration,
                       Double(synth.audio.count) / Self.mp3BytesPerSecond)
        recordMeasuredRate()

        // Resume where the last session left off (only for the saved chapter, and
        // unless it was effectively finished).
        let resume = document.progress.time
        if chapterIndex == document.progress.chapterIndex, resume > 0, resume < duration - 0.5 {
            seekPlayer(to: resume)
            currentTime = resume
            activeIndex = highlightIndex(at: resume)
        }
        return .ready
    }

    /// Point `player` at `source` and take over completion reporting.
    ///
    /// Both end notifications matter and mean different things: reaching the end is
    /// a finished chapter (読了 + auto-advance), while failing to reach it is a
    /// decode failure whose cache entry must be evicted. `AVAudioPlayer` collapsed
    /// both into one `successfully:` flag, and `handlePlaybackFinished` still takes
    /// that shape so the downstream rules are untouched.
    private func attachPlayer(to source: ChapterAudioSource) {
        let queue = DispatchQueue(label: "app.reader.chapter-audio")
        let item = AVPlayerItem(asset: source.makeAsset(queue: queue))
        let p = AVPlayer(playerItem: item)
        // Narration is a long download the user is actively listening to; stalling
        // to re-buffer is worse than a brief gap, and the generator stays ~2.8x
        // ahead of playback anyway.
        p.automaticallyWaitsToMinimizeStalling = false

        endObservers.forEach(NotificationCenter.default.removeObserver)
        // Belongs to the player being replaced, and a boundary observer outlives its
        // usefulness silently — it would end the NEXT chapter at the previous one's length.
        if let endOfAudioObserver { player?.removeTimeObserver(endOfAudioObserver) }
        endOfAudioObserver = nil
        endObservers = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handlePlaybackFinished(successfully: true) }
            },
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handlePlaybackFinished(successfully: false) }
            },
        ]
        audioSource = source
        player = p
    }

    // MARK: - Progressive playback

    /// A chapter being listened to while it is still being generated.
    ///
    /// A class, not a struct: the alignment arrays are appended on every one of
    /// ~1,200 chunks, and value semantics would copy-on-write the whole chapter
    /// each time.
    private final class Progressive {
        let source: ChapterAudioSource
        /// Characters of the NFKC-normalized text that was sent for synthesis —
        /// the alphabet `characters` counts in, so the two divide meaningfully.
        /// The raw chapter text does not: normalization folds half-width katakana,
        /// so its length is not the length the alignment describes.
        let totalChars: Int
        var characters: [String] = []
        var startTimes: [Double] = []
        var endTimes: [Double] = []
        /// Playback has begun — past this point generation always runs to
        /// completion so the chapter reaches the cache.
        var isPlaying = false
        /// Aligned seconds at the last timeline rebuild, to throttle them.
        var timelineBuiltTo: Double = 0
        /// Aligned seconds at the last `duration` re-projection. Tracked separately
        /// from `timelineBuiltTo` because the two want opposite cadences: the
        /// timeline must keep up with the audio, while the projected total is the
        /// scrubber's and the ring's full length and should settle, not twitch.
        var estimateProjectedTo: Double = 0

        init(source: ChapterAudioSource, totalChars: Int) {
            self.source = source
            self.totalChars = totalChars
        }

        var alignment: ReaderCore.Alignment {
            ReaderCore.Alignment(characters: characters, startTimes: startTimes, endTimes: endTimes)
        }

        /// How far the TIMINGS reach. Distinct from `generatedTime` (how far the
        /// AUDIO reaches) because the two streams are not in step: on `eleven_v3`
        /// most chunks carry audio with no alignment at all, and the alignment
        /// frontier measured 1.4–3.1 s ahead of the audio describing it. Pairs with
        /// `characters.count`, so it — not the audio clock — is what may be divided
        /// by a character count to project a total.
        var alignedTime: Double { endTimes.last ?? 0 }
    }

    /// Rough speech rate, used ONLY to size the audio source's advertised length
    /// before any real timing exists. The scrubber does not use it: measured rates
    /// on real chapters ranged 3.6–6.8 chars/s depending on content, so a constant
    /// is wrong by up to 2x — and underestimating makes the scrubber claim the
    /// chapter ended while audio is still playing. The scrubber starts from
    /// `seededDuration` and refines with `estimatedTotal` instead.
    ///
    /// Deliberately at the SLOW end (`eleven_v3` narrating Japanese prose measured
    /// 3.85 chars/s): this divides into the byte estimate, so a rate that is too
    /// fast advertises an asset shorter than the real one — the one direction
    /// `ChapterAudioSource` says truncates playback.
    private static let charsPerSecondOfSpeech = 3.5
    /// 128 kbps mp3, over-estimated: `ChapterAudioSource` treats the advertised
    /// length as the end of the asset, so guessing short would truncate playback.
    private static let bytesPerSecondOfAudio = 20_000.0
    /// The REAL rate, for converting bytes appended into seconds of narration that
    /// exist. ElevenLabs' default output format is `mp3_44100_128` — constant
    /// bitrate, and neither the app nor the Worker ever overrides it — so this is
    /// exact rather than an estimate (measured: 344,861 bytes / 21.551 s).
    private static let mp3BytesPerSecond = 16_000.0
    /// Audio buffered before playback starts. Generation runs faster than playback,
    /// so a short head start is not caught up with.
    private static let headStartSeconds = 4.0
    /// How much new ALIGNMENT to accumulate between timeline rebuilds. Between
    /// rebuilds the highlight cannot advance past the frontier the last one carried,
    /// so this is also how far behind the audio the highlight may fall — keep it
    /// well under the head start. A rebuild is one `CharTokenMapper` pass over a
    /// ≤4k-char chapter and changes no structure, so it is cheap to do often.
    private static let timelineRefreshSeconds = 2.0
    /// How much audio must exist before this chapter's own alignment is trusted to
    /// project a total. The head start is typically a title line and a pause, so a
    /// rate extrapolated from it is unrepresentative by tens of percent — and every
    /// revision moves the ring, the scrubber and the remaining-time readout.
    private static let estimateEvidenceSeconds = 25.0
    /// How much new alignment to accumulate between `duration` re-projections.
    /// Deliberately far coarser than `timelineRefreshSeconds`: `duration` is the
    /// FULL LENGTH of the ring and the scrubber, so every revision jumps the thumb
    /// and the arc — the "it jumps every second, forwards and backwards" report.
    /// Re-projecting rarely (and from steadily more evidence, so each revision is
    /// smaller than the last) lets it converge instead of twitching.
    private static let estimateRefreshSeconds = 20.0

    private var progressive: Progressive?

    /// Whether audio is still being generated for what is currently playing.
    var isGenerating: Bool { progressive?.isPlaying == true }
    /// Seconds of narration that exist so far — the scrubber's buffered extent,
    /// and the limit a seek may travel to.
    private(set) var generatedTime: Double = 0
    /// How much of the chapter exists as audio (0…1). Only meaningful while
    /// `isGenerating`; a finished chapter is entirely available.
    var generatedFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, generatedTime / duration))
    }

    /// Whole minutes of narration this chapter is expected to produce, for the
    /// idle player. Prefers a rate measured from a chapter already generated this
    /// session — same book, voice and model, so it lands within a few percent —
    /// and falls back to a middling constant before anything has been measured.
    var estimatedNarrationMinutes: Int {
        guard seededDuration > 0 else { return 0 }
        return max(1, Int((seededDuration / 60).rounded()))
    }

    /// Chapter length projected from the same measured rate the idle player quotes,
    /// so "about N min" and the scrubber that follows it agree. Unlike a projection
    /// from this chapter's first seconds it does not move as audio arrives, which is
    /// what the scrubber and the remaining-time readout need most while generating.
    private var seededDuration: Double {
        let chars = currentChapter?.text.count ?? 0
        guard chars > 0 else { return 0 }
        return Double(chars) * (services.measuredSecondsPerChar ?? (1 / 5.0))
    }

    /// Chapter indices whose narration is already on disk, for the chapters
    /// sheet's download marks.
    private(set) var cachedChapters: Set<Int> = []

    /// Recompute which chapters have cached audio. Done once when the sheet opens
    /// rather than per row: `has()` touches the filesystem, so a 400-chapter book
    /// would otherwise stat on every scroll frame. Probed exactly the way playback
    /// probes — including the earlier default models playback accepts — so a mark
    /// means the chapter really does play offline. Audio under a previous VOICE still
    /// correctly does not count: that one is a live user choice, not a legacy key.
    func refreshCachedChapters() {
        var found: Set<Int> = []
        for (i, chapter) in document.chapters.enumerated() {
            let request = SynthesisRequest(text: chapter.text, voice: services.narrationVoice)
            if services.audioStore.hasAllowingLegacyModel(request) { found.insert(i) }
        }
        cachedChapters = found
    }

    /// Record what this chapter actually took, so the next one can be estimated
    /// from evidence instead of a constant.
    private func recordMeasuredRate() {
        let chars = currentChapter?.text.count ?? 0
        guard chars > 0, duration > 0 else { return }
        services.measuredSecondsPerChar = duration / Double(chars)
    }

    private func beginProgressivePlayback(key: ContentKey, request: SynthesisRequest, gen: Int) {
        let seconds = Double(request.text.count) / Self.charsPerSecondOfSpeech
        progressive = Progressive(
            source: ChapterAudioSource(expectedBytes: Int(seconds * Self.bytesPerSecondOfAudio)),
            totalChars: Normalize.nfkc(request.text).count)
        generatedTime = 0
        services.synthesisStream.subscribe(key) { [weak self] audio, alignment in
            MainActor.assumeIsolated { self?.appendStreamed(audio, alignment, gen: gen) }
        }
    }

    private func appendStreamed(_ audio: Data, _ alignment: ReaderCore.Alignment, gen: Int) {
        guard gen == loadGeneration, let p = progressive else { return }
        p.source.append(audio)
        p.characters.append(contentsOf: alignment.characters)
        p.startTimes.append(contentsOf: alignment.startTimes)
        p.endTimes.append(contentsOf: alignment.endTimes)
        // Seconds of narration that EXIST, measured from the bytes actually held —
        // not from `endTimes.last`, which is the alignment frontier and runs 1.4–3.1 s
        // ahead of its own audio. Reading the head start, the seek limit and the
        // scrubber's buffered band off the alignment had all three promising
        // narration that had not arrived.
        generatedTime = Double(p.source.byteCount) / Self.mp3BytesPerSecond
        // Real progress, replacing the eased time estimate: this is the fraction of
        // the chapter the stream has actually delivered.
        let totalChars = currentChapter?.text.count ?? 0
        if totalChars > 0 {
            synthesisProgress = min(1, Double(p.characters.count) / Double(totalChars))
        }

        if !p.isPlaying {
            if generatedTime >= Self.headStartSeconds { startProgressivePlayback(p) }
        } else if p.alignedTime - p.timelineBuiltTo >= Self.timelineRefreshSeconds {
            // Throttled on the ALIGNMENT frontier: that is what a rebuild moves, and
            // most chunks carry audio without any, so throttling on audio would rebuild
            // repeatedly with nothing new to fold in.
            p.timelineBuiltTo = p.alignedTime
            refreshTimings(p.alignment)
            // Re-extrapolate only once there is enough audio for this chapter's own
            // rate to beat the seeded one, and then only on its own slow cadence; it
            // converges from there, and is replaced by the exact duration when
            // generation ends.
            if p.alignedTime >= Self.estimateEvidenceSeconds,
               p.alignedTime - p.estimateProjectedTo >= Self.estimateRefreshSeconds {
                p.estimateProjectedTo = p.alignedTime
                duration = estimatedTotal(p)
            }
        }
    }

    /// Total chapter duration projected from the audio generated so far — this
    /// chapter's own measured speech rate, not an average over other content.
    private func estimatedTotal(_ p: Progressive) -> Double {
        let generatedChars = p.characters.count
        // `alignedTime`, not `generatedTime`: this divides seconds by the characters
        // spoken in them, and only the alignment clock counts the same characters.
        guard generatedChars > 0, p.totalChars > 0, p.alignedTime > 0 else { return duration }
        return p.alignedTime * Double(p.totalChars) / Double(generatedChars)
    }

    /// Begin playing what has arrived so far.
    private func startProgressivePlayback(_ p: Progressive) {
        guard let tokens = tokensForSynthesizedText() else { return }
        p.isPlaying = true
        p.timelineBuiltTo = p.alignedTime
        // Structure IS new here (the first spans), so this one bumps the version.
        setTimeline(SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: p.alignment)))
        // Estimated total: the real one isn't known until generation ends, and a
        // scrubber whose length grows under the thumb is worse than one slightly off.
        duration = seededDuration
        attachPlayer(to: p.source)
        // Deliberately NOT `endSynthesisProgress(success: true)`: this is the ~4 s
        // pre-roll ending, not the generation. The measured fraction set moments ago
        // in `appendStreamed` carries across the transition untouched — the collapsed
        // circle keeps showing it while generating, so completing the bar here would
        // read 100% and then fall back to the real figure on the next chunk.
        // Completion is the seal's job (`ensureAudio`, once the request returns).
        audioState = .ready
        play()
    }

    /// Generation finished while its audio was already playing: seal the source and
    /// replace the estimate with the exact alignment. Deliberately does NOT rebuild
    /// the player — that would restart the chapter under the listener.
    private func finishProgressivePlayback(with synth: SynthesizedAudio, gen: Int) {
        guard gen == loadGeneration, let p = progressive else { return }
        p.source.finish()
        refreshTimings(synth.alignment)
        // Same rule as `buildPlayback`: the audio is the authority on its own length,
        // because the alignment may stop short of it (see the note there).
        duration = max(timeline.duration,
                       Double(synth.audio.count) / Self.mp3BytesPerSecond)
        generatedTime = duration
        endPlaybackAtRealEnd(duration)
        recordMeasuredRate()
        progressive = nil
        audioState = .ready
    }

    /// Stop at the chapter's real end rather than at the one `AVPlayer` was told about.
    ///
    /// `AVAssetResourceLoader` asks for the asset's length exactly ONCE, when the item
    /// is attached — which for a progressively generated chapter is long before the
    /// length is known. `ChapterAudioSource` therefore answers with an estimate that
    /// deliberately runs LONG, because advertising short truncates playback outright.
    /// `finish()` corrects the stored value, but nothing re-asks, so the item keeps a
    /// duration derived from the estimate.
    ///
    /// The consequence is audible: past the last real byte `AVPlayer` plays silence
    /// while its clock — and so the highlight and the timer — keep running, and
    /// `didPlayToEndTime` does not fire until that phantom tail elapses. Measured on
    /// the front-matter chapter of 響け！ユーфォニアム 2: 80 characters advertise
    /// 457 KB (28.6 s) against 278 KB of real audio (17.4 s) — eleven seconds of
    /// silence after the narration ended. Cached chapters never showed it because
    /// `buildPlayback` passes the exact byte count.
    ///
    /// A boundary observer rather than the display link: the link is a foreground-only
    /// clock, and a chapter has to end correctly while backgrounded.
    private func endPlaybackAtRealEnd(_ seconds: Double) {
        guard let player, seconds > 0 else { return }
        if let endOfAudioObserver { player.removeTimeObserver(endOfAudioObserver) }
        let end = NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))
        endOfAudioObserver = player.addBoundaryTimeObserver(
            forTimes: [end], queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated { self?.handlePlaybackFinished(successfully: true) }
        }
    }

    /// Generation failed after playback began. The audio on the device is a partial
    /// chapter that can never be completed, so stop rather than let `AVPlayer` stall
    /// silently at the end of the buffer.
    private func abortProgressivePlayback() {
        progressive = nil
        generatedTime = 0
        teardownPlayer()
    }

    /// Replace the span TIMINGS without touching structure. The surfaces and
    /// readings are fixed at load; only their times grow as audio arrives. Going
    /// through `setTimeline` would bump `structureVersion` and relayout the whole
    /// CoreText surface every few seconds mid-playback.
    private func refreshTimings(_ alignment: ReaderCore.Alignment) {
        guard let tokens = tokensForSynthesizedText() else { return }
        timeline = SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: alignment))
    }

    /// The tokens for the text being synthesized. `load()` already tokenized this
    /// chapter under the same normalization the TTS request uses, so this is the
    /// same pass the alignment indexes — no second MeCab run mid-playback.
    private func tokensForSynthesizedText() -> [Token]? {
        guard let loaded = chapterTokens,
              loaded.text == Normalize.nfkc(currentChapter?.text ?? "") else { return nil }
        return loaded.tokens
    }

    /// Drop the player and everything that outlives it. The end-of-item observers
    /// are registered per item, so leaving them attached would deliver a finish for
    /// a chapter that is no longer on screen.
    private func teardownPlayer() {
        player?.pause()
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers = []
        if let endOfAudioObserver { player?.removeTimeObserver(endOfAudioObserver) }
        endOfAudioObserver = nil
        audioSource?.abort()
        audioSource = nil
        player = nil
    }

    /// `AVPlayer` seeks asynchronously; the reader treats the playhead as moved
    /// immediately (the highlight jumps on the same frame), so seek with zero
    /// tolerance to keep audio and highlight from disagreeing after a scrub.
    private func seekPlayer(to t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The playhead, in seconds. `AVPlayer` reports an indefinite time before the
    /// asset is ready, which would otherwise surface as NaN in the scrubber.
    private var playerTime: Double {
        guard let t = player?.currentTime(), t.isNumeric else { return currentTime }
        return t.seconds
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        activateSession()
        if currentTime >= duration, duration > 0 { seekPlayer(to: 0) }
        // `defaultRate` rather than `rate`: setting `rate` directly starts playback
        // itself, which would bypass the session activation ordering above and
        // fights `AVPlayer`'s own rate management on interruption resume.
        player.defaultRate = Float(speed)
        player.play()
        isPlaying = true
        link.start()
        nowPlaying.setPlayback(elapsed: playerTime, rate: speed)
    }

    /// Whether this model has an active audio session. `setActive(true)` is not free
    /// and not idempotent in cost: it blocks the caller while the route is
    /// established, and iOS logs "This method can lead to UI unresponsiveness if
    /// called on the main thread" for every call. `play()` runs on every resume,
    /// every lock-screen command and every interruption recovery, so activating
    /// unconditionally produced that warning in pairs, over and over, and put a
    /// blocking call on the main thread immediately before `player.play()` — the
    /// same window the display-link clock has to survive.
    ///
    /// It tracks OUR activation only, so it must be cleared wherever the system takes
    /// the session away without going through `deactivateSession` — an interruption
    /// (call, Siri, another app) and a media-services reset both do. A stale `true`
    /// there is silence: `play()` would skip the reactivation iOS requires after an
    /// interruption ends, and nothing would ever set it right again.
    private var sessionIsActive = false

    /// Activate the playback audio session at the first real playback — deferred out
    /// of `buildPlayback` so opening a cached chapter doesn't interrupt other audio.
    /// Now Playing rides along: the lock-screen widget exists exactly while the
    /// session does.
    ///
    /// The category is set ONCE per session rather than per play: it never changes,
    /// and setting it is the other half of the same main-thread warning. The
    /// asynchronous `activate(options:completionHandler:)` would remove the block
    /// entirely, but it is iOS 27 and the deployment target is 26 — so the fix here
    /// is to stop making the call N times, not to move it.
    ///
    /// The flag is set only once activation actually SUCCEEDED. `setActive(true)`
    /// throws when another app holds the session non-mixably (a call in progress is
    /// the ordinary case), and remembering that failure as success would skip every
    /// later retry — the reader would stay mute for the rest of its life.
    private func activateSession() {
        if !sessionIsActive {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback)
            sessionIsActive = (try? session.setActive(true)) != nil
        }
        nowPlaying.activate()
        nowPlaying.setMetadata(bookTitle: document.title, chapterTitle: chapterTitle,
                               chapterIndex: chapterIndex, chapterCount: chapterCount,
                               duration: duration)
        nowPlaying.setChapterBounds(hasPrevious: canGoToPreviousChapter,
                                    hasNext: canGoToNextChapter)
    }

    /// Release the session so other apps' audio can resume after we stop.
    private func deactivateSession() {
        guard sessionIsActive else { return }
        sessionIsActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func pause() {
        player?.pause()
        isPlaying = false
        link.stop()
        persistProgress()
        // Settle the highlight on the real playhead. The clock has just stopped, so
        // whatever the last tick left behind is up to a frame stale — and
        // `persistProgress` writes `currentTime` itself, so without this the scrubber
        // and the marker can come to rest describing different moments.
        currentTime = playerTime
        activeIndex = highlightIndex(at: currentTime)
        nowPlaying.setPlayback(elapsed: currentTime, rate: 0)
    }

    func setSpeed(_ v: Double) {
        speed = v
        player?.defaultRate = Float(v)
        // Only touch the live rate while playing — assigning it when paused would
        // start playback from a speed control.
        if isPlaying { player?.rate = Float(v) }
        nowPlaying.setPlayback(elapsed: playerTime, rate: isPlaying ? v : 0)
    }

    /// Move the playhead (scrubbing / VoiceOver adjust). Works while playing or
    /// paused; the highlight jumps to the new position immediately.
    func seek(to t: Double) {
        guard player != nil, duration > 0 else { return }
        // While generating, the audio past `generatedTime` does not exist yet —
        // seeking into it would stall the player with no way back.
        let limit = isGenerating ? min(duration, generatedTime) : duration
        let clamped = min(max(0, t), limit)
        seekPlayer(to: clamped)
        currentTime = clamped
        activeIndex = highlightIndex(at: clamped)
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
        teardownPlayer()        // don't let a stale player replay under a new chapter
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
    /// always written (its playhead has already reset to 0).
    func persistProgress(completed: Bool = false) {
        guard audioState == .ready, duration > 0 else { return }
        let stop: PlaybackStop = completed
            ? .completed
            : .interrupted(time: playerTime)
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
        // Gate on OUR OWN `isPlaying`, never on `AVPlayer.timeControlStatus`.
        //
        // This guard used to stop the clock whenever the player reported `.paused`,
        // which is a state `AVPlayer` enters transiently and on its own: a stall while
        // the resource loader serves the next range, a route or buffer hiccup, the gap
        // between `play()` and the rate actually taking effect. `link.stop()` is
        // TERMINAL — nothing restarts the clock but another `play()` — so one such
        // frame froze `currentTime` and `activeIndex` for the rest of the chapter while
        // the audio played on. That is the "audio ran away from the marker" report:
        // not drifting timings, a dead clock. It needs a real device to reproduce,
        // because the simulator resumes instantly and never stalls.
        //
        // `isPlaying` is set false by exactly the three ends of playback — `pause()`,
        // `stop()`, `handlePlaybackFinished` — each of which stops the link itself, so
        // this is now a backstop rather than the mechanism. A player that stalls
        // forever costs a no-op tick per frame, which is the cheap direction to be
        // wrong in. Natural finish stays owned by the end-of-item notification (it
        // fires backgrounded, where this clock is dead), so nothing is persisted here.
        guard player != nil, isPlaying else {
            link.stop()
            return
        }
        currentTime = playerTime
        activeIndex = highlightIndex(at: currentTime)
    }

    /// The token to LIGHT UP at `t` — the spoken token, never the whitespace
    /// between tokens.
    ///
    /// `MeCabTokenizer` emits the whitespace MeCab drops as gap tokens, so a blank
    /// line between two entries is a real token (`"\n\n"`) and the API charges the
    /// pause between them to it — 1.4–2.0 s, measured. Highlighting it is honest but
    /// unreadable: a whitespace token's rects are the tail of one line, the empty
    /// line, and the head of the next, so the reader paints two or three empty boxes
    /// out in the margin and the word that was just spoken goes dark. In a chapter
    /// of short entries separated by blank lines that is a large share of playback.
    /// Holding the last spoken token instead reads exactly right: the word stays lit
    /// through the pause after it, and the auto-scroll keeps following text rather
    /// than drifting to a blank line.
    /// Deliberately whitespace ONLY, not `hasWordChar`: punctuation carries the
    /// sentence pause and draws a visible box against the text it follows, which
    /// reads correctly. Whitespace is the case with nothing to draw on.
    private func highlightIndex(at t: Double) -> Int? {
        guard let i = timeline.index(at: t) else { return nil }
        // Walk back over the gap run; a leading gap (an indented first line) has no
        // predecessor to hold, so it correctly yields nothing.
        var k = i
        while k >= 0, let span = timeline[k],
              span.surface.allSatisfy(\.isWhitespace) { k -= 1 }
        return k >= 0 ? k : nil
    }

    /// Natural end of the chapter — routed through the end-of-item notification so
    /// it also runs while backgrounded (screen locked). Marks the chapter complete
    /// (読了), then continues into the next chapter IF its narration is already
    /// local — an unattended finish must never trigger a paid synthesis (the same
    /// rule as the lock-screen skip). Without a cached continuation the lock-screen
    /// widget is kept (paused at the end) so a pocketed phone still has transport;
    /// only the audio session is released.
    private func handlePlaybackFinished(successfully: Bool) {
        isPlaying = false
        link.stop()
        guard successfully else {
            // Failed to play to the end (`failedToPlayToEndTime`): NOT a finished
            // read — don't mark it 読了 or auto-advance on it, and don't touch saved
            // progress. The data produced a decode error, so evict the cache entry
            // (a retry would replay the same broken bytes) and surface the failure;
            // Play regenerates.
            teardownPlayer()
            services.audioStore.remove(
                SynthesisRequest(text: currentChapter?.text ?? "",
                                 voice: services.narrationVoice).cacheKey)
            audioState = .failed(L10n.readerFailedAudio)
            // Tear the widget down with the player: unlike the kept-at-chapter-end
            // widget (whose player still exists), remote Play here would hit a nil
            // player and dead-end — a lock screen with nonfunctional controls.
            nowPlaying.deactivate()
            deactivateSession()
            return
        }
        currentTime = duration
        activeIndex = highlightIndex(at: duration)
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
        // Same probe `load()` will run when the chapter opens, legacy models included —
        // the gate has to agree with it, or the advance either refuses a chapter that
        // would have played free or opens one it cannot play without paying.
        return services.audioStore.hasAllowingLegacyModel(
            SynthesisRequest(text: document.chapters[next].text,
                             voice: services.narrationVoice))
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
            // iOS has already deactivated our session — it did not go through
            // `deactivateSession`, so record that here or the resume below would skip
            // the reactivation and `player.play()` would run against a dead session.
            sessionIsActive = false
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
