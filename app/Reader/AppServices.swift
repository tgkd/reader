import Foundation
import ReaderCore
import RevenueCat

/// The app's composed services. The real production path is wired here:
/// ElevenLabs via the aiwork Worker + on-disk cache + persisted library.
/// Swapping an impl happens HERE — no view or model changes. TTS is
/// `WorkerTTSService` (needs a subscribed X-User-ID), wrapped by
/// `ChunkingTTSService` for >9k-char chapters and content-addressed disk caching.
@MainActor
final class AppServices {
    /// All tokenization goes through this actor: off the main thread (the
    /// ~50 MB IPADic load + per-chapter tokenize used to stall the reader-open
    /// transition) and serialized (MeCab is not thread-safe). Still lazy — the
    /// dictionary loads on the first tokenize, not on the launch path.
    let tokenizerWorker = TokenizerWorker()

    let tts: TTSService
    /// Paid synthesis, owned at session scope so it survives the reader that
    /// started it (leave ≠ cancel, reopen ≠ re-bill). See `SynthesisCoordinator`.
    let synthesis: SynthesisCoordinator
    /// Live audio chunks from an in-flight synthesis, so the reader can start
    /// playing a chapter while the rest of it is still being generated.
    let synthesisStream = SynthesisStream()
    /// Seconds of narration per character, measured from chapters actually
    /// generated. Rates ranged 3.6–6.8 chars/s across content, so a constant is
    /// wrong by up to 2x — but within one voice it is consistent, which is exactly
    /// the case that matters for estimating the NEXT chapter.
    ///
    /// Persisted per voice rather than held for the session. Session scope meant
    /// every cold launch fell back to the constant, so the first chapter after
    /// launch was seeded visibly wrong and then jumped when enough audio existed
    /// to re-project — the case a reviewer and every new user hits. Keying by
    /// voice keeps the self-healing property (switching voices reads that voice's
    /// own rate, or nothing) without discarding what was already measured. The
    /// model is deliberately NOT in the key: unlike a cache key, a stale estimate
    /// bills nothing and strands nothing, and it is replaced at the first seal.
    var measuredSecondsPerChar: Double? {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.rateKey(narrationVoice))
            return stored > 0 ? stored : nil
        }
        set {
            // Clamped to 2–10 chars/s. Measured content sits well inside that; a
            // wilder value means a pathological chapter (long leading silence, a
            // page of punctuation), and persistence would otherwise keep it
            // forever where session scope used to discard it at relaunch.
            guard let newValue, (0.1...0.5).contains(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: Self.rateKey(narrationVoice))
        }
    }

    private static func rateKey(_ voice: Voice) -> String { "measuredSecondsPerChar.\(voice.id)" }
    let fixtures: FixtureTTSService   // concrete, for the library "cached?" probe
    let audioStore: GeneratedAudioStore
    let library: LibraryStore
    let dictionary: DictionaryService

    init() {
        // Concrete fixtures service kept only for the library's "cached?" probe
        // (`FixtureTTSService.hasFixture`); it is not in the playback chain.
        fixtures = FixtureTTSService()

        let store = DiskAudioStore()
        audioStore = store

        // Chapters over the ElevenLabs per-request char cap are chunked and the
        // alignments stitched back together — transparently to the reader/cache.
        let stream = synthesisStream
        let worker = WorkerTTSService(
            baseURL: AppServices.workerBaseURL, userId: { AppServices.userId },
            onChunk: { key, audio, alignment in
                stream.publish(key, audio: audio, alignment: alignment)
            })
        tts = ChunkingTTSService(inner: worker, store: store)
        synthesis = SynthesisCoordinator(tts: tts, store: store)

        // Installs start with an EMPTY shelf — the user imports their own books.
        library = DiskLibraryStore(starter: [])

        // Real tap-to-define over the bundled compact jisho DB; fall back to the
        // seeded mock if the DB resource is absent (e.g. a build that skipped
        // scripts/build-compact-dict.sh).
        let sqlite: DictionaryService? = SQLiteDictionaryService()
        dictionary = sqlite ?? MockDictionaryService.seeded()
    }

    /// The narration voice for synthesis and cache probes — the persisted Settings
    /// pick, mirrored here by `AppModel`. Changing it drops the memoized
    /// first-chapter keys so the Library's downloaded badges re-probe under the
    /// new voice's cache keys.
    var narrationVoice: Voice = .shizuka {
        didSet { if narrationVoice != oldValue { contentKeyCache.removeAll() } }
    }

    /// First-chapter `ContentKey` per document, cached here (not in the view-owned
    /// `LibraryModel`, which a Library↔Reader route switch recreates — so its cache
    /// was cold on every return, re-hashing every book's first chapter on the main
    /// actor). Survives route switches; invalidated on delete and on voice change.
    private var contentKeyCache: [Document.ID: ContentKey] = [:]

    /// The audio cache key for a document's first chapter (the "is it downloaded?"
    /// probe), memoized across Library reappearances.
    func firstChapterKey(for document: Document) -> ContentKey {
        if let cached = contentKeyCache[document.id] { return cached }
        let key = SynthesisRequest(text: document.chapters.first?.text ?? "",
                                   voice: narrationVoice).cacheKey
        contentKeyCache[document.id] = key
        return key
    }

    /// Drop a document's cached key (on delete).
    func invalidateKey(for id: Document.ID) { contentKeyCache[id] = nil }

    /// The `reader Pro` entitlement (RevenueCat identifier) the reader is gated on.
    static let entitlementID = "reader Pro"

    /// Configure RevenueCat once, at launch, if the `RevenueCatKey` Info.plist key
    /// (set via the gitignored xcconfig) is present. No key → no-op. Called from
    /// `YomiApp.init()` so `Purchases.shared.appUserID` is ready before any
    /// `AppServices` reads it (the anonymous id becomes the Worker's X-User-ID).
    /// The key is configured verbatim on every platform — no build-flavor or
    /// device branches (a silently skipped key once shipped a build that looked
    /// subscribed but 401'd at the Worker). A `test_…` key on a physical device
    /// fails loudly in RevenueCat instead of being quietly ignored; on-device
    /// builds need the real App Store (`appl_…`) public key.
    static func configureRevenueCat() {
        guard !Purchases.isConfigured, let key = revenueCatKey, !key.isEmpty else { return }
        Purchases.configure(withAPIKey: key)
    }

    /// Reclaim a deleted document's cached narration so it doesn't linger in the
    /// audio cache. Removes each chapter's whole-chapter entry plus any per-segment
    /// entries a chunked chapter left behind (normally pruned post-stitch, but a
    /// crash between synth and the whole-chapter save could orphan some). Mirrors
    /// `ChunkingTTSService`'s split so the segment keys match. Idempotent.
    func purgeAudio(for document: Document) async {
        // `ContentKey` is content-addressed, not document-addressed: a re-import of the
        // same file, or two books sharing a chapter, resolve to the SAME cache entry.
        // Whatever the surviving shelf still points at is not this document's to
        // reclaim — removing it (or cancelling its in-flight paid request) would strip
        // narration the other book already paid for. Compare under the same
        // normalization the key is built from.
        let stillReferenced = Set(
            library.all()
                .filter { $0.id != document.id }
                .flatMap(\.chapters)
                .map { Normalize.nfkc($0.text) }
        )
        for chapter in document.chapters {
            let normalized = Normalize.nfkc(chapter.text)
            guard !stillReferenced.contains(normalized) else { continue }
            // Sweep every catalog voice AND every model: the user may have listened
            // to this book under an earlier voice or model default, whose entries
            // live under other keys. Both are in `ContentKey`, so a sweep that
            // assumes today's defaults leaves the old audio on disk forever —
            // undeletable per-book, reclaimable only by clearing the whole cache.
            // Segments are re-split per model because the chunk cap is per-model.
            for model in SynthesisModel.allCases {
                let segments = Chunker.split(normalized, maxChars: model.maxRequestChars)
                for voice in Voice.catalog {
                    let key = SynthesisRequest(text: normalized, voice: voice, model: model).cacheKey
                    // A synthesis still running for this chapter would save its result
                    // AFTER the purge and resurrect audio for a book that no longer
                    // exists — unreachable, and only reclaimable by clearing the whole
                    // cache. `cancel` alone is not a barrier (it only sets a flag, and a
                    // response already in hand still saves on resume), so WAIT for the
                    // task to unwind before deleting. Deleting the book is the explicit
                    // destructive action, so abandoning its request is the intended
                    // outcome here; merely LEAVING the reader still must not cancel
                    // (see SynthesisCoordinator).
                    await synthesis.cancelAndWait(key)
                    audioStore.remove(key)
                    if segments.count > 1 {
                        for segment in segments {
                            audioStore.remove(
                                SynthesisRequest(text: segment, voice: voice, model: model).cacheKey)
                        }
                    }
                }
            }
        }
    }

    /// Local subscription check backing the reader's paywall gate: `true` iff
    /// RevenueCat is configured AND `reader Pro` is active. An unconfigured build
    /// (no key) reads NOT subscribed in EVERY flavor — its requests carry no
    /// X-User-ID, so the Worker 401s them anyway, and the old ungated-`true`
    /// shipped a build that showed "active" while every synthesis failed. No
    /// DEBUG/Release branches: debug and device must behave identically. Checked
    /// locally so the (paid) Worker is never hit for a non-subscriber — which
    /// would also poison its negative-result cache.
    func isSubscribed() async -> Bool {
        guard Purchases.isConfigured else { return false }
        let info = try? await Purchases.shared.customerInfo()
        return info?.entitlements[AppServices.entitlementID]?.isActive == true
    }

    /// RevenueCat's pushed updates to the `reader Pro` state, each element the
    /// freshly-resolved entitlement. A renewal, an expiry, a refund or a purchase
    /// made on another device changes the tier without going through this app's
    /// purchase/restore callbacks (`AppModel.entitlementTick`), so a view that read
    /// `isSubscribed()` once keeps showing the old tier for as long as it stays on
    /// screen — subscriber-only controls offered to a lapsed user, the upsell
    /// hidden from them. Views that gate on the entitlement follow this instead.
    /// Finishes immediately when RevenueCat is unconfigured (which always reads
    /// not-subscribed, so there is nothing to follow).
    func entitlementUpdates() -> AsyncStream<Bool> {
        guard Purchases.isConfigured else { return AsyncStream { $0.finish() } }
        let entitlement = AppServices.entitlementID
        return AsyncStream { continuation in
            let task = Task {
                for await info in Purchases.shared.customerInfoStream {
                    continuation.yield(info.entitlements[entitlement]?.isActive == true)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// OCR engine for scanned-PDF pages (those with no text layer) — the Worker's
    /// cloud OCR (Gemini via AI Gateway), gated on subscription. `nil` for
    /// non-subscribers: a scanned import then surfaces a Membership prompt, while
    /// text / EPUB / .txt import never needs OCR. On-device OCR was removed — its
    /// quality wasn't good enough for a reading app.
    func ocrRecognizer() async -> PDFTextRecognizer? {
        guard await isSubscribed() else { return nil }
        // Each import gets its own recognizer, but they share the in-flight page
        // registry: nothing serializes imports, and OCR is billed per page, so two
        // overlapping imports of the same scan must not POST the same image twice.
        return WorkerOCRService(baseURL: AppServices.workerBaseURL, userId: AppServices.userId,
                                inFlight: ocrInFlight)
    }

    /// Session-scoped OCR request coalescer shared by every recognizer this app
    /// hands out (see `ocrRecognizer`).
    private let ocrInFlight = OCRInFlightPages()

    /// The RevenueCat appUserID for the Worker's X-User-ID header — the real
    /// appUserID once RevenueCat is configured. `nil` (no key) leaves the header
    /// unset → the Worker's 401 path. Nonisolated: read per-request from the TTS
    /// path's concurrent chunk tasks; RevenueCat's accessors are thread-safe.
    nonisolated private static var userId: String? {
        Purchases.isConfigured ? Purchases.shared.appUserID : nil
    }

    /// iOS public SDK key from the `RevenueCatKey` Info.plist key (set via the
    /// gitignored xcconfig), else nil. The public key ships in the binary, but
    /// keeping it out of the committed source matches the redacted-host convention.
    private static var revenueCatKey: String? {
        let plist = Bundle.main.object(forInfoDictionaryKey: "RevenueCatKey") as? String
        return (plist?.isEmpty == false) ? plist : nil
    }

    /// Worker base URL for the TTS/OCR path: the `WorkerBaseURL` Info.plist key
    /// (WORKER_HOST override in the gitignored xcconfig), else the production
    /// Worker. The host is not a secret (it ships in every IPA and appears in CT
    /// logs) and every billable route is auth-gated server-side, so defaulting to
    /// prod is safe — and it removes the silently-broken build class where a
    /// missing WORKER_HOST baked in a host that doesn't resolve.
    private static var workerBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "WorkerBaseURL") as? String
        // Require a real host: an empty WORKER_HOST expands the plist value to
        // "https://", which is non-empty and URL-parses but has no host — that would
        // slip past a bare isEmpty check and defeat the production fallback below.
        if let raw, let url = URL(string: raw), url.host?.isEmpty == false { return url }
        return URL(string: "https://api.thetango.org")!
    }
}
