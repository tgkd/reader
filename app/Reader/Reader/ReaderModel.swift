import SwiftUI
import AVFoundation
import QuartzCore
import ReaderCore
import struct ReaderCore.Document

@MainActor
@Observable
final class ReaderModel {
    enum LoadState: Equatable { case loading, ready, failed(String) }
    enum AudioState: Equatable { case locked, idle, synthesizing, ready, notGenerated, failed(String) }

    let document: Document
    private let services: AppServices

    private(set) var loadState: LoadState = .loading
    private(set) var audioState: AudioState = .locked
    private(set) var timeline = SpanTimeline([])
    private(set) var structureVersion = 0
    private(set) var activeIndex: Int?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var synthesisProgress: Double = 0

    var speed: Double = 1.0
    var chromeVisible = true

    private(set) var chapterIndex = 0
    var chaptersVisible = false

    private(set) var entry: DictionaryEntry?
    var sheetVisible = false

    private var player: AVPlayer?
    private var audioSource: ChapterAudioSource?
    private let speech = AVSpeechSynthesizer()
    private let nowPlaying = NowPlayingController()
    private let link = DisplayLinkProxy()
    private var playbackTask: Task<Void, Never>?
    private var endObservers: [NSObjectProtocol] = []
    private var endOfAudioObserver: Any?
    nonisolated(unsafe) private var interruptionObserver: NSObjectProtocol?
    nonisolated(unsafe) private var routeChangeObserver: NSObjectProtocol?
    nonisolated(unsafe) private var mediaResetObserver: NSObjectProtocol?
    private var wasPlayingBeforeInterruption = false
    private var isSwitchingChapter = false
    private var chapterTokens: (text: String, tokens: [Token])?
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

    private func tokenizeWithSourceReadings(_ text: String) async -> [Token]? {
        guard let tokens = await services.tokenizerWorker.tokenize(text) else { return nil }
        guard let chapter = currentChapter, !chapter.sourceReadings.isEmpty,
              chapter.text == text else { return tokens }
        return SourceReadingOverlay.apply(chapter.sourceReadings, to: tokens, text: text)
    }

    func startAudio() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in await self?.requestAudioAndPlay() }
    }

    func requestAudioAndPlay() async {
        switch audioState {
        case .ready: play(); return
        case .synthesizing, .locked: return
        case .idle, .notGenerated, .failed: break
        }
        synthesisProgress = 0
        audioState = .synthesizing
        chromeVisible = true
        if await ensureAudio() { play() }
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
                                       voice: services.narrationVoice)
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
                beginSynthesisProgress(charCount: request.text.count)
                beginProgressivePlayback(key: key, request: request, gen: gen)
                defer {
                    services.synthesisStream.unsubscribe(key)
                    if progressive != nil { abortProgressivePlayback() }
                }
                synth = try await services.synthesis.task(for: request).value
                endSynthesisProgress(success: true)
                if progressive?.isPlaying == true {
                    finishProgressivePlayback(with: synth, gen: gen)
                    return audioState == .ready
                }
                progressive = nil
            } catch is CancellationError {
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .idle }
                return false
            } catch let e as URLError where e.code == .cancelled {
                endSynthesisProgress(success: false)
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
            } catch is URLError {
                endSynthesisProgress(success: false)
                if gen == loadGeneration { audioState = .failed(L10n.readerFailedNetwork) }
                return false
            } catch {
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
        setTimeline(SpanTimeline(CharTokenMapper.map(tokens: tokens, alignment: synth.alignment)))

        guard !synth.audio.isEmpty else { return .undecodable }
        let source = ChapterAudioSource(expectedBytes: synth.audio.count)
        source.append(synth.audio)
        source.finish()
        attachPlayer(to: source)
        duration = max(timeline.duration,
                       Double(synth.audio.count) / Self.mp3BytesPerSecond)
        recordMeasuredRate()

        let resume = document.progress.time
        if chapterIndex == document.progress.chapterIndex, resume > 0, resume < duration - 0.5 {
            seekPlayer(to: resume)
            currentTime = resume
            activeIndex = highlightIndex(at: resume)
        }
        return .ready
    }

    private func attachPlayer(to source: ChapterAudioSource) {
        let queue = DispatchQueue(label: "app.reader.chapter-audio")
        let item = AVPlayerItem(asset: source.makeAsset(queue: queue))
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = false

        endObservers.forEach(NotificationCenter.default.removeObserver)
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
    }

    private static let charsPerSecondOfSpeech = 3.5
    private static let bytesPerSecondOfAudio = 20_000.0
    private static let mp3BytesPerSecond = 16_000.0
    private static let headStartSeconds = 4.0
    private static let timelineRefreshSeconds = 2.0
    private static let estimateEvidenceSeconds = 25.0
    private static let estimateRefreshSeconds = 20.0

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
        generatedTime = Double(p.source.byteCount) / Self.mp3BytesPerSecond
        let totalChars = currentChapter?.text.count ?? 0
        if totalChars > 0 {
            synthesisProgress = min(1, Double(p.characters.count) / Double(totalChars))
        }

        if !p.isPlaying {
            if generatedTime >= Self.headStartSeconds { startProgressivePlayback(p) }
        } else if p.alignedTime - p.timelineBuiltTo >= Self.timelineRefreshSeconds {
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
        let generatedChars = p.characters.count
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

    private func finishProgressivePlayback(with synth: SynthesizedAudio, gen: Int) {
        guard gen == loadGeneration, let p = progressive else { return }
        p.source.finish(reconcilingWith: synth.audio)
        refreshTimings(synth.alignment)
        duration = max(timeline.duration,
                       Double(synth.audio.count) / Self.mp3BytesPerSecond)
        generatedTime = duration
        endPlaybackAtRealEnd(duration)
        recordMeasuredRate()
        progressive = nil
        audioState = .ready
    }

    private func endPlaybackAtRealEnd(_ seconds: Double) {
        guard let player, seconds > 0 else { return }
        if let endOfAudioObserver { player.removeTimeObserver(endOfAudioObserver) }
        endOfAudioObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                guard time.seconds >= seconds - 0.1 else { return }
                self.handlePlaybackFinished(successfully: true)
            }
        }
    }

    private func abortProgressivePlayback() {
        progressive = nil
        generatedTime = 0
        teardownPlayer()
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
        player?.pause()
        endObservers.forEach(NotificationCenter.default.removeObserver)
        endObservers = []
        if let endOfAudioObserver { player?.removeTimeObserver(endOfAudioObserver) }
        endOfAudioObserver = nil
        audioSource?.abort()
        audioSource = nil
        player = nil
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
        activateSession()
        if currentTime >= duration, duration > 0 { seekPlayer(to: 0) }
        player.defaultRate = Float(speed)
        player.play()
        isPlaying = true
        link.start()
        nowPlaying.setPlayback(elapsed: playerTime, rate: speed)
    }

    private var sessionIsActive = false

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
        currentTime = playerTime
        activeIndex = highlightIndex(at: currentTime)
        nowPlaying.setPlayback(elapsed: currentTime, rate: 0)
    }

    func setSpeed(_ v: Double) {
        speed = v
        player?.defaultRate = Float(v)
        if isPlaying { player?.rate = Float(v) }
        nowPlaying.setPlayback(elapsed: playerTime, rate: isPlaying ? v : 0)
    }

    func seek(to t: Double) {
        guard player != nil, duration > 0 else { return }
        let limit = isGenerating ? min(duration, generatedTime) : duration
        let clamped = min(max(0, t), limit)
        seekPlayer(to: clamped)
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
        loadGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        teardownPlayer()
        duration = 0
        isPlaying = false
        nowPlaying.deactivate()
        deactivateSession()
        link.stop()
    }

    func saveProgressOnLeave() {
        persistProgress()
        persistChapterPosition()
    }

    private func persistChapterPosition() {
        guard audioState != .ready,
              document.chapters.indices.contains(chapterIndex),
              chapterIndex != document.progress.chapterIndex else { return }
        var doc = document
        doc.progress = ReadingProgress(chapterIndex: chapterIndex, time: 0,
                                       fraction: Double(chapterIndex) / Double(max(1, chapterCount)))
        services.library.save(doc)
    }

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
        guard player != nil, isPlaying else {
            link.stop()
            return
        }
        currentTime = playerTime
        activeIndex = highlightIndex(at: currentTime)
    }

    private func highlightIndex(at t: Double) -> Int? {
        guard let i = timeline.index(at: t) else { return nil }
        var k = i
        while k >= 0, let span = timeline[k],
              span.surface.allSatisfy(\.isWhitespace) { k -= 1 }
        return k >= 0 ? k : nil
    }

    private func handlePlaybackFinished(successfully: Bool) {
        isPlaying = false
        link.stop()
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
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable,
              isPlaying else { return }
        pause()
    }

    func tapToken(_ i: Int) {
        guard let span = timeline[i], hasWordChar(span.surface) else { return }
        let lemma = span.dictionaryForm ?? span.surface
        entry = services.dictionary.lookup(dictionaryForm: lemma, reading: span.reading)
            ?? DictionaryEntry(id: -1, word: span.surface, reading: span.reading ?? "",
                               senses: [Sense(glosses: [L10n.dictNotFound], partsOfSpeech: ["—"])])
        sheetVisible = true
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
        s.unicodeScalars.contains { sc in
            let v = sc.value
            return (0x3041...0x3096).contains(v)
                || (0x30A1...0x30FA).contains(v)
                || (0x4E00...0x9FFF).contains(v)
                || (0x0030...0x0039).contains(v)
                || (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v)
        }
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
