import SwiftUI
import AVFoundation
import QuartzCore
import ReaderCore
import struct ReaderCore.Document

@MainActor
@Observable
final class ReaderModel {
    enum LoadState: Equatable { case loading, ready, failed(String) }
    enum AudioState: Equatable {
        case locked, idle, synthesizing, ready, notGenerated, interrupted, failed(String)
    }

    private(set) var document: Document
    private let services: AppServices

    private(set) var loadState: LoadState = .loading
    private(set) var audioState: AudioState = .locked
    private(set) var timeline = SpanTimeline([])
    private(set) var structureVersion = 0
    private(set) var activeIndex: Int?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private var wantsPlayback = false
    private(set) var synthesisProgress: Double = 0

    static let supportedSpeeds: [Double] = [0.75, 1.0, 1.25, 1.5]

    private(set) var speed: Double = 1.0
    var chromeVisible = true

    private(set) var chapterIndex = 0
    private(set) var initialToken: Int?
    private var visibleToken: Int?
    private var visibleTokenChapter: Int?
    var chaptersVisible = false

    private(set) var entry: DictionaryEntry?
    private(set) var lookupChoices: [LookupChoice] = []
    private(set) var selectedChoice: String = ""
    var sheetVisible = false

    private var player: AVPlayer?
    private var audioSource: ChapterAudioSource?
    private let speech = AVSpeechSynthesizer()
    private let nowPlaying = NowPlayingController()
    private let link = DisplayLinkProxy()
    private var playbackTask: Task<Void, Never>?
    private var endObservers: [NSObjectProtocol] = []
    private var endOfAudioObserver: Any?
    private var lastAdvance: (time: Double, at: Double)?
    private var exactSwapObserver: Any?
    private var pendingExactSwap: (audio: Data, audioSeconds: Double)?
    private static let swapSilenceSeconds = 0.5
    private static let swapLeadSeconds = 0.15
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaResetObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    private var isSwitchingChapter = false
    private var backgroundedDuringSynthesis = false
    private var chapterAudioIsPartial = false
    private var chapterTokens: (text: String, tokens: [Token])?
    private var rawChapterTokens: [Chapter.ID: DocumentLexicon.ChapterTokens] = [:]
    private var loadGeneration = 0

    init(document: Document, services: AppServices) {
        self.document = document
        self.services = services
        let saved = document.progress.chapterIndex
        chapterIndex = document.chapters.indices.contains(saved) ? saved : 0
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.handleRouteChange(note) }
        }
        mediaResetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionIsActive = false }
        }
        nowPlaying.onPlay = { [weak self] in self?.play() }
        nowPlaying.onPause = { [weak self] in self?.pause() }
        nowPlaying.onTogglePlayPause = { [weak self] in self?.togglePlay() }
        nowPlaying.onSeek = { [weak self] t in self?.seek(to: t) }
        nowPlaying.supportedPlaybackRates = Self.supportedSpeeds
        nowPlaying.onPlaybackRate = { [weak self] r in self?.setSpeed(r) }
        nowPlaying.onNextChapter = { [weak self] in
            guard let self else { return }
            Task { await self.remoteOpenChapter(1) }
        }
        nowPlaying.onPreviousChapter = { [weak self] in
            guard let self else { return }
            Task { await self.remoteOpenChapter(-1) }
        }
    }

    deinit {
        link.stop()
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        if let mediaResetObserver { NotificationCenter.default.removeObserver(mediaResetObserver) }
    }

    var spans: [TokenSpan] { timeline.spans }
    var progressFraction: Double { duration > 0 ? min(1, currentTime / duration) : 0 }

    private func setTimeline(_ t: SpanTimeline) {
        timeline = t
        structureVersion &+= 1
    }

    var currentChapter: Chapter? {
        document.chapters.indices.contains(chapterIndex) ? document.chapters[chapterIndex] : document.chapters.first
    }
    var chapterCount: Int { document.chapters.count }
    var hasChapters: Bool { chapterCount > 1 }
    var chapterTitle: String { currentChapter?.title ?? L10n.chapterNumber(chapterIndex + 1) }
    var canGoToPreviousChapter: Bool { chapterIndex > 0 }
    var canGoToNextChapter: Bool { chapterIndex < chapterCount - 1 }

    func load() async {
        loadGeneration &+= 1
        let gen = loadGeneration
        loadState = .loading
        link.onTick = { [weak self] in MainActor.assumeIsolated { self?.tick() } }

        let text = currentChapter?.text ?? ""
        let tokens = await tokenizeWithSourceReadings(text)
        guard gen == loadGeneration, !Task.isCancelled else { return }
        guard let tokens else {
            loadState = .failed(L10n.readerFailedTokenizer); return
        }
        chapterTokens = (Normalize.nfkc(text), tokens)
        setTimeline(SpanTimeline(untimedTokens: tokens))
        initialToken = savedToken()
        if visibleTokenChapter != chapterIndex {
            visibleToken = initialToken
            visibleTokenChapter = chapterIndex
        }
        loadState = .ready

        let request = SynthesisRequest(text: text, voice: services.narrationVoice)
        let key = request.cacheKey
        if let (cachedKey, cached) = services.audioStore.loadAllowingLegacyModel(request) {
            switch await buildPlayback(from: cached, gen: gen) {
            case .ready:
                audioState = .ready
                return
            case .undecodable:
                services.audioStore.remove(cachedKey)
            case .aborted:
                return
            }
        }

        let subscribed = await services.isSubscribed()
        guard gen == loadGeneration, !Task.isCancelled else { return }
        audioState = subscribed ? .idle : .locked
        if subscribed, services.synthesis.isSynthesizing(key) {
            startAudio()
        }
    }

    private var bookLexicon: [PronunciationRule]?

    private func pronunciationRules() async -> [PronunciationRule] {
        if let bookLexicon { return bookLexicon }
        let built = await DocumentLexicon.build(for: document,
                                                using: services.tokenizerWorker,
                                                seeded: rawChapterTokens)
        rawChapterTokens = built.rawTokensByChapterID
        bookLexicon = built.lexicon.rules
        return built.lexicon.rules
    }

    private func tokenizeWithSourceReadings(_ text: String) async -> [Token]? {
        guard let raw = await rawTokens(for: text) else { return nil }
        return pageTokens(from: raw, text: text)
    }

    private func rawTokens(for text: String) async -> [Token]? {
        let normalized = Normalize.nfkc(text)
        let annotated = currentChapter.map { $0.text == text && !$0.sourceReadings.isEmpty } ?? false
        if annotated, let chapter = currentChapter,
           let retained = rawChapterTokens[chapter.id], retained.normalizedText == normalized {
            return retained.tokens
        }
        guard let tokens = await services.tokenizerWorker.tokenize(text) else { return nil }
        if annotated, let chapter = currentChapter {
            rawChapterTokens[chapter.id] = DocumentLexicon.ChapterTokens(normalizedText: normalized,
                                                                         tokens: tokens)
        }
        return tokens
    }

    private func pageTokens(from raw: [Token], text: String) -> [Token] {
        guard let chapter = currentChapter, !chapter.sourceReadings.isEmpty,
              chapter.text == text else { return raw }
        return SourceReadingOverlay.apply(chapter.sourceReadings, to: raw, text: text)
    }

    func startAudio() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in await self?.requestAudioAndPlay() }
    }

    func requestAudioAndPlay() async {
        switch audioState {
        case .ready: play(); return
        case .synthesizing, .locked: return
        case .idle, .notGenerated, .interrupted, .failed: break
        }
        if chapterAudioIsPartial { teardownPlayer() }
        backgroundedDuringSynthesis = false
        synthesisProgress = 0
        audioState = .synthesizing
        chromeVisible = true
        wantsPlayback = true
        if await ensureAudio(), wantsPlayback { play() }
    }

    func cancelSynthesis() {
        guard audioState == .synthesizing else { return }
        services.synthesis.cancel(
            SynthesisRequest(text: currentChapter?.text ?? "",
                             voice: services.narrationVoice).cacheKey)
        playbackTask?.cancel()
    }

    private func beginSynthesisProgress(charCount: Int) {
        synthesisProgress = 0
    }

    private func endSynthesisProgress(success: Bool) {
        synthesisProgress = success ? 1 : 0
    }

    private func ensureAudio() async -> Bool {
        if player != nil { audioState = .ready; return true }
        let gen = loadGeneration
        let request = SynthesisRequest(text: currentChapter?.text ?? "",
                                       voice: services.narrationVoice,
                                       pronunciation: await pronunciationRules())
        let key = request.cacheKey

        let synth: SynthesizedAudio
        if let cached = services.audioStore.loadAllowingLegacyModel(request)?.audio {
            synth = cached
        } else {
            if !services.synthesis.isSynthesizing(key) {
                let subscribed = await services.isSubscribed()
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
                beginSynthesisProgress(charCount: request.text.value.count)
                // Only stream when this reader is the one about to start the task. SynthesisStream
                // keeps no replay buffer, so joining a run somebody else started delivers the
                // middle of the chapter as if it were the beginning — play the finished audio
                // instead, which costs the wait but is the chapter the listener asked for.
                if !services.synthesis.isSynthesizing(key) {
                    beginProgressivePlayback(key: key, request: request, gen: gen)
                }
                defer {
                    services.synthesisStream.unsubscribe(key)
                    if gen == loadGeneration, progressive != nil { endProgressivePlayback() }
                }
                synth = try await services.synthesis.task(for: request).value
                guard gen == loadGeneration else { return false }
                endSynthesisProgress(success: true)
                if progressive?.isPlaying == true {
                    finishProgressivePlayback(with: synth, gen: gen)
                    return audioState == .ready
                }
                progressive = nil
            } catch is CancellationError {
                endSynthesisProgress(success: false)
                discardPartialAudio()
                if gen == loadGeneration { audioState = .idle }
                return false
            } catch let e as URLError where e.code == .cancelled {
                endSynthesisProgress(success: false)
                discardPartialAudio()
                if gen == loadGeneration { audioState = .idle }
                return false
            } catch is FixtureTTSService.FixtureError {
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .notGenerated }
                return false
            } catch WorkerTTSService.WorkerError.subscriptionRequired {
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .locked }
                return false
            } catch let error as URLError {
                WorkerTTSService.log.error("""
                    [yomi] synthesis URLError \(error.code.rawValue, privacy: .public) \
                    \(String(reflecting: error), privacy: .public)
                    """)
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = stateAfterSynthesisFailure(L10n.readerFailedNetwork) }
                return false
            } catch {
                WorkerTTSService.log.error("""
                    [yomi] synthesis threw: \(String(reflecting: error), privacy: .public) \
                    partial=\(self.chapterAudioIsPartial, privacy: .public) \
                    backgrounded=\(self.backgroundedDuringSynthesis, privacy: .public)
                    """)
                endSynthesisProgress(success: false)
                if gen == loadGeneration {
                    audioState = stateAfterSynthesisFailure(error.localizedDescription)
                }
                return false
            }
        }

        switch await buildPlayback(from: synth, gen: gen) {
        case .ready:
            audioState = .ready
            return true
        case .undecodable:
            services.audioStore.remove(key)
            fallthrough
        case .aborted:
            endSynthesisProgress(success: false)
            if gen == loadGeneration {
                audioState = Task.isCancelled ? .idle : .failed(L10n.readerFailedAudio)
            }
            return false
        }
    }

    private enum PlaybackBuild { case ready, undecodable, aborted }

    private func buildPlayback(from synth: SynthesizedAudio, gen: Int) async -> PlaybackBuild {
        guard gen == loadGeneration, !Task.isCancelled else { return .aborted }

        let tokens: [Token]?
        if let loaded = chapterTokens, loaded.text == synth.text {
            tokens = loaded.tokens
        } else {
            tokens = await tokenizeWithSourceReadings(synth.text)
        }
        guard let tokens, gen == loadGeneration, !Task.isCancelled else { return .aborted }
        let alignment = synth.alignment.repairingCollapsedRuns(audioSeconds: synth.audioSeconds)
        logChapterAlignment("loaded", synth, repairedTo: alignment.endTimes.last ?? 0)
        setTimeline(SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: alignment)))

        guard !synth.audio.isEmpty else { return .undecodable }
        let source = ChapterAudioSource(expectedBytes: synth.audio.count)
        source.append(synth.audio)
        source.finish()
        attachPlayer(to: source)
        let audioSeconds = Double(synth.audio.count) / NarrationAudio.mp3BytesPerSecond
        duration = max(timeline.duration, audioSeconds)
        watchForStalledEnd(audioSeconds)
        recordMeasuredRate()

        let resume = document.progress.time
        if chapterIndex == document.progress.chapterIndex, resume > 0, resume < duration - 0.5 {
            seekPlayer(to: resume)
            currentTime = resume
            activeIndex = highlightIndex(at: resume)
        }
        return .ready
    }

    private func makeItem(for source: ChapterAudioSource) -> AVPlayerItem {
        let queue = DispatchQueue(label: "app.reader.chapter-audio")
        return AVPlayerItem(asset: source.makeAsset(queue: queue))
    }

    private func observeEnd(of item: AVPlayerItem) {
        endObservers.forEach(NotificationCenter.default.removeObserver)
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
    }

    private func attachPlayer(to source: ChapterAudioSource) {
        let item = makeItem(for: source)
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false

        if let endOfAudioObserver { player?.removeTimeObserver(endOfAudioObserver) }
        endOfAudioObserver = nil
        lastAdvance = nil
        observeEnd(of: item)
        audioSource = source
        player = p
    }

    /// Replace the growing, over-advertised item with one whose byte length is exact.
    ///
    /// A progressive source has to declare its length before a single byte exists, and the guess
    /// runs long by half — so `AVPlayerItem` believes in a tail that never arrives and never posts
    /// `didPlayToEndTime`. Once synthesis seals, the real length is known, so the chapter finishes
    /// on the same item shape a cached chapter uses and completion has one implementation instead
    /// of two. The cost is a brief re-buffer, once, mid-chapter.
    private func scheduleExactAudioSwap(_ audio: Data, alignment: ReaderCore.Alignment,
                                        audioSeconds: Double) {
        cancelPendingExactSwap()
        let now = playerTime
        guard let player, isPlaying,
              let silence = alignment.nextSilence(after: now + Self.swapLeadSeconds,
                                                  minimumSeconds: Self.swapSilenceSeconds),
              silence.lowerBound + Self.swapLeadSeconds < audioSeconds - 1 else {
            WorkerTTSService.log.info(
                "[yomi] exact swap immediate at=\(self.playerTime, privacy: .public)")
            swapInExactAudio(audio)
            watchForStalledEnd(audioSeconds)
            return
        }
        let at = max(now + 0.05, silence.lowerBound + Self.swapLeadSeconds)
        WorkerTTSService.log.info("""
            [yomi] exact swap scheduled now=\(now, privacy: .public) at=\(at, privacy: .public) \
            silence=\(silence.lowerBound, privacy: .public)-\(silence.upperBound, privacy: .public)
            """)
        pendingExactSwap = (audio, audioSeconds)
        exactSwapObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: at, preferredTimescale: 600))], queue: .main
        ) { [weak self] in
            MainActor.assumeIsolated { self?.performPendingExactSwap() }
        }
    }

    private func performPendingExactSwap() {
        if let exactSwapObserver { player?.removeTimeObserver(exactSwapObserver) }
        exactSwapObserver = nil
        guard let pending = pendingExactSwap else { return }
        pendingExactSwap = nil
        WorkerTTSService.log.info(
            "[yomi] exact swap performed at=\(self.playerTime, privacy: .public) playing=\(self.isPlaying, privacy: .public)")
        swapInExactAudio(pending.audio)
        watchForStalledEnd(pending.audioSeconds)
    }

    private func cancelPendingExactSwap() {
        if let exactSwapObserver { player?.removeTimeObserver(exactSwapObserver) }
        exactSwapObserver = nil
        pendingExactSwap = nil
    }

    private func swapInExactAudio(_ audio: Data) {
        guard let player, !audio.isEmpty else { return }
        let resumeAt = playerTime

        let exact = ChapterAudioSource(expectedBytes: audio.count)
        exact.append(audio)
        exact.finish()

        let outgoing = audioSource
        let item = makeItem(for: exact)
        if let endOfAudioObserver { player.removeTimeObserver(endOfAudioObserver) }
        endOfAudioObserver = nil
        lastAdvance = nil
        observeEnd(of: item)
        player.replaceCurrentItem(with: item)
        audioSource = exact
        outgoing?.abort()

        // Seek before resuming: the replacement item starts unbuffered, and this player does not
        // wait to minimise stalling.
        player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.player?.play()
            }
        }
    }

    private final class Progressive {
        let source: ChapterAudioSource
        let totalChars: Int
        var characters: [String] = []
        var startTimes: [Double] = []
        var endTimes: [Double] = []
        var isPlaying = false
        var timelineBuiltTo: Double = 0
        var estimateProjectedTo: Double = 0

        init(source: ChapterAudioSource, totalChars: Int) {
            self.source = source
            self.totalChars = totalChars
        }

        var alignment: ReaderCore.Alignment {
            ReaderCore.Alignment(characters: characters, startTimes: startTimes, endTimes: endTimes)
        }

        var alignedTime: Double { endTimes.last ?? 0 }

        var describedChars: Int { characters.joined().count }
    }

    private static let charsPerSecondOfSpeech = 3.5
    private static let bytesPerSecondOfAudio = 20_000.0
    private static let headStartSeconds = 4.0
    private static let timelineRefreshSeconds = 2.0
    private static let timelineSafetySeconds = 1.5
    private static let timelineRefresh = TimelineRefreshPolicy(
        batchSeconds: timelineRefreshSeconds, safetySeconds: timelineSafetySeconds)
    private static let estimateEvidenceSeconds = 25.0
    private static let estimateRefreshSeconds = 20.0
    private static let stallWindowSeconds = 2.5
    private static let stallGraceSeconds = 1.5

    private var progressive: Progressive?

    var isGenerating: Bool { progressive?.isPlaying == true }
    private(set) var generatedTime: Double = 0
    var generatedFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, generatedTime / duration))
    }

    var estimatedNarrationMinutes: Int {
        guard seededDuration > 0 else { return 0 }
        return max(1, Int((seededDuration / 60).rounded()))
    }

    private var seededDuration: Double {
        let chars = currentChapter?.text.count ?? 0
        guard chars > 0 else { return 0 }
        return Double(chars) * (services.measuredSecondsPerChar ?? (1 / 5.0))
    }

    private(set) var cachedChapters: Set<Int> = []

    func refreshCachedChapters() {
        var found: Set<Int> = []
        for (i, chapter) in document.chapters.enumerated() {
            let request = SynthesisRequest(text: chapter.text, voice: services.narrationVoice)
            if services.audioStore.hasAllowingLegacyModel(request) { found.insert(i) }
        }
        cachedChapters = found
    }

    private func recordMeasuredRate() {
        let chars = currentChapter?.text.count ?? 0
        guard chars > 0, duration > 0 else { return }
        services.measuredSecondsPerChar = duration / Double(chars)
    }

    private func beginProgressivePlayback(key: ContentKey, request: SynthesisRequest, gen: Int) {
        let seconds = Double(request.text.value.count) / Self.charsPerSecondOfSpeech
        progressive = Progressive(
            source: ChapterAudioSource(expectedBytes: Int(seconds * Self.bytesPerSecondOfAudio)),
            totalChars: request.text.value.count)
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
        generatedTime = Double(p.source.byteCount) / NarrationAudio.mp3BytesPerSecond
        if p.totalChars > 0 {
            synthesisProgress = min(1, Double(p.describedChars) / Double(p.totalChars))
        }

        if !p.isPlaying {
            if generatedTime >= Self.headStartSeconds { startProgressivePlayback(p) }
        } else if Self.timelineRefresh.shouldRebuild(alignedTime: p.alignedTime,
                                                    builtTo: p.timelineBuiltTo,
                                                    timedExtent: timeline.timedExtent,
                                                    playhead: playerTime,
                                                    rate: speed) {
            p.timelineBuiltTo = p.alignedTime
            refreshTimings(p.alignment)
            if p.alignedTime >= Self.estimateEvidenceSeconds,
               p.alignedTime - p.estimateProjectedTo >= Self.estimateRefreshSeconds {
                p.estimateProjectedTo = p.alignedTime
                duration = estimatedTotal(p)
            }
        }
    }

    private func estimatedTotal(_ p: Progressive) -> Double {
        let generatedChars = p.describedChars
        guard generatedChars > 0, p.totalChars > 0, p.alignedTime > 0 else { return duration }
        return p.alignedTime * Double(p.totalChars) / Double(generatedChars)
    }

    private func startProgressivePlayback(_ p: Progressive) {
        guard let tokens = tokensForSynthesizedText() else { return }
        p.isPlaying = true
        p.timelineBuiltTo = p.alignedTime
        setTimeline(SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: p.alignment)))
        duration = seededDuration
        attachPlayer(to: p.source)
        audioState = .ready
        play()
    }

    private func logChapterAlignment(_ event: String, _ synth: SynthesizedAudio, repairedTo: Double) {
        let key = SynthesisRequest(text: synth.text, voice: services.narrationVoice).cacheKey.value.prefix(12)
        let pauses = synth.alignment.pauseAttribution()
        WorkerTTSService.log.info("""
            [yomi] chapter \(event, privacy: .public) key=\(key, privacy: .public) \
            chapter=\(self.chapterIndex, privacy: .public) voice=\(self.services.narrationVoice.id, privacy: .public) \
            source=\(synth.alignmentSource.rawValue, privacy: .public) chars=\(synth.text.count, privacy: .public) \
            audioSeconds=\(synth.audioSeconds, privacy: .public) \
            delta=\(synth.audioSeconds - (synth.alignment.endTimes.last ?? 0), privacy: .public) \
            repairedDelta=\(synth.audioSeconds - repairedTo, privacy: .public) \
            collapsedRuns=\(synth.alignment.collapsedSpeechRuns.count, privacy: .public) \
            pausesOnSpeech=\(pauses.onSpeech, privacy: .public) \
            pausesOnPunctuation=\(pauses.onPunctuation, privacy: .public)
            """)
    }

    private func finishProgressivePlayback(with synth: SynthesizedAudio, gen: Int) {
        guard gen == loadGeneration, progressive != nil else { return }
        logChapterAlignment("sealed", synth, repairedTo: synth.alignment.endTimes.last ?? 0)
        let audioSeconds = Double(synth.audio.count) / NarrationAudio.mp3BytesPerSecond
        refreshTimings(synth.alignment)
        duration = max(timeline.duration, audioSeconds)
        generatedTime = duration
        scheduleExactAudioSwap(synth.audio, alignment: synth.alignment, audioSeconds: audioSeconds)
        recordMeasuredRate()
        progressive = nil
        audioState = .ready
    }

    /// Backstop for a player that stops without saying so.
    ///
    /// `didPlayToEndTime` is the primary signal and, on an exact-length item, fires on its own.
    /// This catches a playhead that simply stops on the last frames: without it the manually
    /// latched `isPlaying` never clears and the transport goes on offering pause for a chapter that
    /// has already ended. Deliberately NOT a "close enough to the end" trip — that races the real
    /// ending and clips the last fraction of a second off every chapter.
    private func watchForStalledEnd(_ seconds: Double) {
        guard let player, seconds > 0 else { return }
        if let endOfAudioObserver { player.removeTimeObserver(endOfAudioObserver) }
        lastAdvance = nil
        endOfAudioObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.checkForStalledEnd(at: time.seconds, target: seconds) }
        }
    }

    /// Only inside the closing seconds. A stall before that is buffering, where the established
    /// behaviour is to keep showing pause rather than to guess that the chapter ended.
    private func checkForStalledEnd(at time: Double, target: Double) {
        guard isPlaying, time > target - Self.stallWindowSeconds else {
            lastAdvance = nil
            return
        }
        let now = CACurrentMediaTime()
        guard let last = lastAdvance else {
            lastAdvance = (time, now)
            return
        }
        if time > last.time + 0.05 {
            lastAdvance = (time, now)
        } else if now - last.at >= Self.stallGraceSeconds {
            handlePlaybackFinished(successfully: true)
        }
    }

    private func abortProgressivePlayback() {
        progressive = nil
        generatedTime = 0
        teardownPlayer()
    }

    private func endProgressivePlayback() {
        guard let p = progressive, p.isPlaying, player != nil, audioSource === p.source else {
            abortProgressivePlayback()
            return
        }
        let received = p.source.bytes
        guard !received.isEmpty else {
            abortProgressivePlayback()
            return
        }
        swapInExactAudio(received)
        refreshTimings(p.alignment)
        let audioSeconds = Double(received.count) / NarrationAudio.mp3BytesPerSecond
        duration = audioSeconds
        generatedTime = audioSeconds
        currentTime = min(currentTime, audioSeconds)
        watchForStalledEnd(audioSeconds)
        chapterAudioIsPartial = true
        progressive = nil
    }

    private func discardPartialAudio() {
        if chapterAudioIsPartial { teardownPlayer() }
    }

    private func stateAfterSynthesisFailure(_ message: String) -> AudioState {
        if chapterAudioIsPartial { return .ready }
        return backgroundedDuringSynthesis ? .interrupted : .failed(message)
    }

    private func refreshTimings(_ alignment: ReaderCore.Alignment) {
        guard let tokens = tokensForSynthesizedText() else { return }
        timeline = SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: alignment))
    }

    private func tokensForSynthesizedText() -> [Token]? {
        guard let loaded = chapterTokens,
              loaded.text == Normalize.nfkc(currentChapter?.text ?? "") else { return nil }
        return loaded.tokens
    }

    private func teardownPlayer() {
        cancelPendingExactSwap()
        player?.pause()
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers = []
        if let endOfAudioObserver { player?.removeTimeObserver(endOfAudioObserver) }
        endOfAudioObserver = nil
        audioSource?.abort()
        audioSource = nil
        player = nil
        lastAdvance = nil
        chapterAudioIsPartial = false
    }

    private func seekPlayer(to t: Double) {
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private var playerTime: Double {
        guard let t = player?.currentTime(), t.isNumeric else { return currentTime }
        return t.seconds
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        wantsPlayback = true
        activateSession()
        if currentTime >= duration, duration > 0 { seekPlayer(to: 0) }
        lastAdvance = nil
        player.defaultRate = Float(speed)
        player.play()
        isPlaying = true
        link.start()
        nowPlaying.setPlayback(elapsed: playerTime, rate: speed)
    }

    private var sessionIsActive = false
    private var outputLatency = 0.0

    private func refreshOutputLatency() {
        outputLatency = AVAudioSession.sharedInstance().outputLatency
    }

    private func activateSession() {
        if !sessionIsActive {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback)
            sessionIsActive = (try? session.setActive(true)) != nil
        }
        refreshOutputLatency()
        nowPlaying.activate()
        nowPlaying.setMetadata(bookTitle: document.title, chapterTitle: chapterTitle,
                               chapterIndex: chapterIndex, chapterCount: chapterCount,
                               duration: duration)
        nowPlaying.setChapterBounds(hasPrevious: canGoToPreviousChapter,
                                    hasNext: canGoToNextChapter)
    }

    private func deactivateSession() {
        guard sessionIsActive else { return }
        sessionIsActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func pause() {
        wantsPlayback = false
        player?.pause()
        isPlaying = false
        link.stop()
        performPendingExactSwap()
        persistProgress()
        currentTime = playerTime
        activeIndex = highlightIndex(at: currentTime - outputLatency)
        nowPlaying.setPlayback(elapsed: currentTime, rate: 0)
    }

    func setSpeed(_ v: Double) {
        guard Self.supportedSpeeds.contains(v) else { return }
        speed = v
        player?.defaultRate = Float(v)
        if isPlaying { player?.rate = Float(v) }
        nowPlaying.setPlayback(elapsed: playerTime, rate: isPlaying ? v : 0)
    }

    func seek(to t: Double) {
        guard player != nil, duration > 0 else { return }
        let limit = isGenerating ? min(duration, generatedTime) : duration
        let clamped = min(max(0, t), limit)
        performPendingExactSwap()
        seekPlayer(to: clamped)
        lastAdvance = nil
        currentTime = clamped
        activeIndex = highlightIndex(at: clamped)
        nowPlaying.setPlayback(elapsed: clamped, rate: isPlaying ? speed : 0)
    }

    func toggleChrome() {
        guard audioState != .synthesizing else { return }
        chromeVisible.toggle()
    }

    func openChapter(_ i: Int) async {
        chaptersVisible = false
        guard !isSwitchingChapter, document.chapters.indices.contains(i), i != chapterIndex else { return }
        isSwitchingChapter = true
        stop()
        chapterIndex = i
        currentTime = 0
        activeIndex = nil
        duration = 0
        setTimeline(SpanTimeline([]))
        await load()
        isSwitchingChapter = false
    }

    private func remoteOpenChapter(_ delta: Int) async {
        await openChapter(chapterIndex + delta)
        if audioState == .ready { play() }
    }

    func stop() {
        saveProgressOnLeave()
        wantsPlayback = false
        loadGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        progressive = nil
        generatedTime = 0
        teardownPlayer()
        duration = 0
        isPlaying = false
        nowPlaying.deactivate()
        deactivateSession()
        link.stop()
    }

    func saveProgressOnLeave() {
        if !persistProgress() { persistChapterPosition() }
    }

    func sceneDidEnterBackground() {
        saveProgressOnLeave()
        if audioState == .synthesizing { backgroundedDuringSynthesis = true }
    }

    func reconcileOnForeground() async {
        guard audioState == .synthesizing || audioState == .interrupted else { return }
        let gen = loadGeneration
        let request = SynthesisRequest(text: currentChapter?.text ?? "",
                                       voice: services.narrationVoice)
        let key = request.cacheKey

        if let (cachedKey, cached) = services.audioStore.loadAllowingLegacyModel(request) {
            discardPartialAudio()
            switch await buildPlayback(from: cached, gen: gen) {
            case .ready:
                endSynthesisProgress(success: true)
                audioState = .ready
            case .undecodable:
                services.audioStore.remove(cachedKey)
            case .aborted:
                break
            }
            return
        }

        if services.synthesis.isSynthesizing(key) {
            if audioState == .interrupted { startAudio() }
            return
        }

        if audioState == .synthesizing {
            endSynthesisProgress(success: false)
            audioState = stateAfterSynthesisFailure(L10n.readerFailedNetwork)
        }
    }

    func noteVisibleToken(_ index: Int) { visibleToken = index }

    private func savedToken() -> Int? {
        guard chapterIndex == document.progress.chapterIndex,
              document.progress.charOffset > 0 else { return nil }
        return TokenOffsets.token(atCharOffset: document.progress.charOffset, in: timeline.spans)
    }

    private func persistChapterPosition() {
        guard document.chapters.indices.contains(chapterIndex) else { return }
        let sameChapter = chapterIndex == document.progress.chapterIndex
        let offset = visibleToken.map { TokenOffsets.charOffset(ofToken: $0, in: timeline.spans) } ?? 0
        guard !sameChapter || offset != document.progress.charOffset else { return }
        var progress = sameChapter ? document.progress : ReadingProgress(chapterIndex: chapterIndex)
        progress.charOffset = offset
        var doc = document
        doc.progress = progress
        services.library.save(doc)
        document = doc
    }

    @discardableResult
    func persistProgress(completed: Bool = false) -> Bool {
        guard audioState == .ready, duration > 0 else { return false }
        let stop: PlaybackStop = completed
            ? .completed
            : .interrupted(time: playerTime)
        guard let progress = ReadingProgressResolver.resolve(stop, duration: duration,
                                                             chapterIndex: chapterIndex)
        else { return false }
        currentTime = progress.time
        var stored = progress
        stored.charOffset = visibleToken.map {
            TokenOffsets.charOffset(ofToken: $0, in: timeline.spans)
        } ?? 0
        var doc = document
        doc.progress = stored
        services.library.save(doc)
        document = doc
        return true
    }

    private func tick() {
        guard player != nil, isPlaying else {
            link.stop()
            return
        }
        currentTime = playerTime
        activeIndex = highlightIndex(at: currentTime - outputLatency)
        #if DEBUG
        logHighlight()
        #endif
    }

    #if DEBUG
    /// `YOMI_HIGHLIGHT_DEBUG=1` prints what the pill is actually tracking.
    ///
    /// Running the tokenizer and replaying the CoreText geometry both ruled themselves out as
    /// explanations for a pill that looked like it covered only part of a word — the token is whole
    /// and the rect spans it. What was never captured is which token was active at the time, so
    /// that is what this prints: if the answer is a lone punctuation token, the walk in
    /// `highlightIndex` was the cause.
    private static let highlightDebug =
        ProcessInfo.processInfo.environment["YOMI_HIGHLIGHT_DEBUG"] != nil
    @ObservationIgnored private var loggedIndex = Int.min

    private func logHighlight() {
        let current = activeIndex ?? -1
        guard Self.highlightDebug, current != loggedIndex else { return }
        loggedIndex = current
        let at = String(format: "%.2f", currentTime)
        guard let i = activeIndex, let span = timeline[i] else {
            print("HL t=\(at) index=nil"); return
        }
        let raw = timeline.index(at: currentTime)
        print("HL t=\(at) index=\(i) beforeWalk=\(raw.map(String.init) ?? "nil") "
              + "surface=\(span.surface.debugDescription) reading=\(span.reading ?? "-") "
              + "span=\(String(format: "%.2f–%.2f", span.start, span.end)) "
              + "matched=\(span.matchedChars)")
    }
    #endif

    private func highlightIndex(at t: Double) -> Int? {
        guard let i = timeline.index(at: t) else { return nil }
        var k = i
        // Punctuation is a token of its own, and a pill sitting on a lone 「!」 reads as the word
        // before it having been skipped. Walk back to the last span with something to say, so
        // punctuation is highlighted as part of the word it follows.
        while k >= 0, let span = timeline[k], !hasWordChar(span.surface) { k -= 1 }
        return k >= 0 ? k : nil
    }

    private func handlePlaybackFinished(successfully: Bool) {
        cancelPendingExactSwap()
        isPlaying = false
        link.stop()
        lastAdvance = nil
        guard successfully else {
            teardownPlayer()
            services.audioStore.remove(
                SynthesisRequest(text: currentChapter?.text ?? "",
                                 voice: services.narrationVoice).cacheKey)
            audioState = .failed(L10n.readerFailedAudio)
            nowPlaying.deactivate()
            deactivateSession()
            return
        }
        player?.pause()
        currentTime = duration
        activeIndex = highlightIndex(at: duration)
        guard !chapterAudioIsPartial else {
            persistProgress()
            teardownPlayer()
            audioState = .interrupted
            nowPlaying.deactivate()
            deactivateSession()
            return
        }
        persistProgress(completed: true)
        if canGoToNextChapter, nextChapterAudioCached {
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

    private var nextChapterAudioCached: Bool {
        let next = chapterIndex + 1
        guard document.chapters.indices.contains(next) else { return false }
        return services.audioStore.hasAllowingLegacyModel(
            SynthesisRequest(text: document.chapters[next].text,
                             voice: services.narrationVoice))
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
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

    private func handleRouteChange(_ note: Notification) {
        refreshOutputLatency()
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable,
              isPlaying else { return }
        pause()
    }

    func tapToken(_ i: Int) {
        guard let span = timeline[i], hasWordChar(span.surface) else { return }
        let candidates = spanLookupCandidates(
            spans: timeline.spans, at: i,
            isWord: { [weak self] in self?.hasWordChar($0) ?? false },
            info: { [weak self] in self?.services.dictionary.surfaceInfo($0) ?? nil }
        )
        let lemma = span.dictionaryForm ?? span.surface
        let choices = candidates.map { candidate in
            LookupChoice(surface: candidate.surface,
                         query: candidate.isSeed ? lemma : candidate.surface,
                         reading: candidate.isSeed ? span.reading : nil)
        }
        lookupChoices = choices.isEmpty
            ? [LookupChoice(surface: span.surface, query: lemma, reading: span.reading)]
            : choices
        resolve(lookupChoices[0])
        sheetVisible = true
    }

    func selectChoice(_ surface: String) {
        guard surface != selectedChoice,
              let choice = lookupChoices.first(where: { $0.surface == surface }) else { return }
        resolve(choice)
    }

    private func resolve(_ choice: LookupChoice) {
        selectedChoice = choice.surface
        entry = services.dictionary.lookup(dictionaryForm: choice.query, reading: choice.reading)
            ?? DictionaryEntry(id: -1, word: choice.surface, reading: choice.reading ?? "",
                               senses: [Sense(glosses: [L10n.dictNotFound], partsOfSpeech: ["—"])])
    }

    func pronounceEntry() {
        guard let entry else { return }
        let text = entry.reading.isEmpty ? entry.word : entry.reading
        guard !text.isEmpty else { return }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        speech.speak(utterance)
    }

    func timeLabel(_ sec: Double) -> String {
        let s = max(0, Int(sec.rounded()))
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }

    private func hasWordChar(_ s: String) -> Bool {
        Furigana.hasWordCharacter(s)
    }
}

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
