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
    /// Lazy so the ~50 MB IPADic load happens on first reader open, NOT on the
    /// launch path / first frame.
    lazy var tokenizer: MeCabTokenizer? = try? MeCabTokenizer()

    let tts: TTSService
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
        let worker = WorkerTTSService(baseURL: AppServices.workerBaseURL, userId: AppServices.userId)
        tts = ChunkingTTSService(inner: worker, store: store)

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
    var narrationVoice: Voice = .george {
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
    static func configureRevenueCat() {
        guard !Purchases.isConfigured, let key = revenueCatKey, !key.isEmpty else { return }
        #if !targetEnvironment(simulator)
        // RevenueCat "Test Store" keys (test_…) are a simulator/sandbox-testing
        // construct and crash when configured against real StoreKit on a physical
        // device. Skip them on device — on-device subscriptions need a real App
        // Store (appl_…) public key.
        guard !key.hasPrefix("test_") else { return }
        #endif
        Purchases.configure(withAPIKey: key)
    }

    /// Reclaim a deleted document's cached narration so it doesn't linger in the
    /// audio cache. Removes each chapter's whole-chapter entry plus any per-segment
    /// entries a chunked chapter left behind (normally pruned post-stitch, but a
    /// crash between synth and the whole-chapter save could orphan some). Mirrors
    /// `ChunkingTTSService`'s split so the segment keys match. Idempotent.
    func purgeAudio(for document: Document) {
        for chapter in document.chapters {
            let normalized = Normalize.nfkc(chapter.text)
            let segments = Chunker.split(normalized)
            // Sweep every catalog voice: the user may have listened to this book
            // under a previous voice pick, whose entries live under other keys.
            for voice in Voice.catalog {
                audioStore.remove(SynthesisRequest(text: normalized, voice: voice).cacheKey)
                if segments.count > 1 {
                    for segment in segments {
                        audioStore.remove(SynthesisRequest(text: segment, voice: voice).cacheKey)
                    }
                }
            }
        }
    }

    /// Local subscription check backing the reader's paywall gate. When RevenueCat
    /// isn't configured (dev/offline, or a device without an `appl_` key) it's
    /// ungated (`true`), so fixture/Worker behavior is unchanged; otherwise `true`
    /// iff `reader Pro` is active. Checked locally so the (paid) Worker is never hit
    /// for a non-subscriber — which would also poison its negative-result cache.
    func isSubscribed() async -> Bool {
        guard Purchases.isConfigured else { return true }
        let info = try? await Purchases.shared.customerInfo()
        return info?.entitlements[AppServices.entitlementID]?.isActive == true
    }

    /// OCR engine for scanned-PDF pages (those with no text layer) — the Worker's
    /// cloud OCR (Gemini via AI Gateway), gated on subscription. `nil` for
    /// non-subscribers: a scanned import then surfaces a Membership prompt, while
    /// text / EPUB / .txt import never needs OCR. On-device OCR was removed — its
    /// quality wasn't good enough for a reading app.
    func ocrRecognizer() async -> PDFTextRecognizer? {
        guard await isSubscribed() else { return nil }
        return WorkerOCRService(baseURL: AppServices.workerBaseURL, userId: AppServices.userId)
    }

    /// The RevenueCat appUserID for the Worker's X-User-ID header — the real
    /// appUserID once RevenueCat is configured. `nil` (no key) leaves the header
    /// unset → the Worker's 401 path.
    private static var userId: String? {
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
