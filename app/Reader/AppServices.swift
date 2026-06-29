import Foundation
import ReaderCore
import RevenueCat

/// The app's composed services. The real production path is wired here:
/// ElevenLabs via the aiwork Worker + on-disk cache + persisted library.
/// Swapping an impl happens HERE — no view or model changes.
///
/// TTS wiring:
///  • Release → `WorkerTTSService` only (production; needs a subscribed X-User-ID).
///  • DEBUG → captured fixtures first, Worker behind them, so the simulator
///    plays the starter texts offline. `READER_FORCE_WORKER=1` skips fixtures to
///    exercise the Worker directly; `READER_USER_ID=<id>` supplies a test
///    X-User-ID until RevenueCat is wired.
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
        #if DEBUG
        // `READER_RESET=1` wipes the persisted shelf + narration cache before the
        // stores load — a clean slate for device/sim testing without deleting the
        // app (which would also reset the RevenueCat appUserID).
        if ProcessInfo.processInfo.environment["READER_RESET"] == "1" { AppServices.purgeLocalData() }
        #endif

        let fx = FixtureTTSService()
        fixtures = fx

        let store = DiskAudioStore()
        audioStore = store

        let worker = WorkerTTSService(baseURL: AppServices.workerBaseURL, userId: AppServices.userId)
        let base: TTSService
        #if DEBUG
        let forceWorker = ProcessInfo.processInfo.environment["READER_FORCE_WORKER"] == "1"
        base = forceWorker ? worker : FallbackTTSService(primary: fx, fallback: worker)
        #else
        base = worker
        #endif
        // Chapters over the ElevenLabs per-request char cap are chunked and the
        // alignments stitched back together — transparently to the reader/cache.
        tts = ChunkingTTSService(inner: base, store: store)

        // Real installs start with an EMPTY shelf — the user imports their own
        // books. The sample texts (with their canned progress) are dev-only and
        // opt-in: DEBUG + `READER_SEED=1` loads them whenever the shelf is empty
        // (so it works even after a persisted-empty launch), without clobbering real
        // imports. Keeps the sim offline tests / `READER_OPEN=<index>` hooks working.
        let lib = DiskLibraryStore(starter: [])
        #if DEBUG
        if ProcessInfo.processInfo.environment["READER_SEED"] == "1", lib.all().isEmpty {
            SeedLibrary.documents.forEach { lib.save($0) }
        }
        #endif
        library = lib

        // Real tap-to-define over the bundled compact jisho DB; fall back to the
        // seeded mock if the DB resource is absent (e.g. a build that skipped
        // scripts/build-compact-dict.sh).
        let sqlite: DictionaryService? = SQLiteDictionaryService()
        dictionary = sqlite ?? MockDictionaryService.seeded()
    }

    /// Configure RevenueCat once, at launch, if a public SDK key is available
    /// (`READER_RC_KEY` env on the sim, or the `RevenueCatKey` Info.plist key on
    /// device). No key → no-op, and the app still runs offline on fixtures. Called
    /// from `YomiApp.init()` so `Purchases.shared.appUserID` is ready before any
    /// `AppServices` reads it. In DEBUG it prints the appUserID, so you can grant
    /// that id a promotional entitlement in the RevenueCat dashboard.
    /// The `reader Pro` entitlement (RevenueCat identifier) the reader is gated on.
    static let entitlementID = "reader Pro"

    static func configureRevenueCat() {
        guard !Purchases.isConfigured, let key = revenueCatKey, !key.isEmpty else { return }
        #if !targetEnvironment(simulator)
        // RevenueCat "Test Store" keys (test_…) are a simulator/sandbox-testing
        // construct and crash when configured against real StoreKit on a physical
        // device. Skip them on device — on-device subscriptions need a real App
        // Store (appl_…) public key.
        guard !key.hasPrefix("test_") else { return }
        #endif
        #if DEBUG
        // Configure as a specific SDK user — e.g. a fresh, UNSUBSCRIBED id — to
        // exercise the paywall gate in the sim (the default anonymous id may already
        // hold a promo entitlement). nil → anonymous.
        let appUserID = ProcessInfo.processInfo.environment["READER_RC_USER"]
        #else
        let appUserID: String? = nil
        #endif
        Purchases.configure(withAPIKey: key, appUserID: appUserID)
        #if DEBUG
        print("RevenueCat appUserID = \(Purchases.shared.appUserID)")
        #endif
    }

    /// Reclaim a deleted document's cached narration so it doesn't linger in the
    /// audio cache. Removes each chapter's whole-chapter entry plus any per-segment
    /// entries a chunked chapter left behind (normally pruned post-stitch, but a
    /// crash between synth and the whole-chapter save could orphan some). Mirrors
    /// `ChunkingTTSService`'s split so the segment keys match. Idempotent.
    func purgeAudio(for document: Document) {
        for chapter in document.chapters {
            let normalized = Normalize.nfkc(chapter.text)
            audioStore.remove(SynthesisRequest(text: normalized).cacheKey)
            let segments = Chunker.split(normalized)
            if segments.count > 1 {
                for segment in segments { audioStore.remove(SynthesisRequest(text: segment).cacheKey) }
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

    #if DEBUG
    /// Delete the persisted shelf (`library.json`) + narration cache. Backs the
    /// `READER_RESET=1` launch hook.
    private static func purgeLocalData() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: appSupport.appendingPathComponent("library.json"))
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        try? fm.removeItem(at: caches.appendingPathComponent("Narration", isDirectory: true))
    }
    #endif

    /// The RevenueCat appUserID for the Worker's X-User-ID header. A DEBUG env
    /// override (`READER_USER_ID`) wins for deterministic tests; otherwise it's the
    /// real appUserID once RevenueCat is configured. `nil` (no key) leaves the
    /// header unset → the Worker's 401 path.
    private static var userId: String? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["READER_USER_ID"], !override.isEmpty {
            return override
        }
        #endif
        return Purchases.isConfigured ? Purchases.shared.appUserID : nil
    }

    /// iOS public SDK key, resolved like `workerBaseURL`: DEBUG/sim launch env
    /// first, then the `RevenueCatKey` Info.plist key (set via a gitignored xcconfig
    /// for release), else nil. The public key ships in the binary, but keeping it
    /// out of the committed source matches the redacted-host convention.
    private static var revenueCatKey: String? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["READER_RC_KEY"], !raw.isEmpty { return raw }
        #endif
        let plist = Bundle.main.object(forInfoDictionaryKey: "RevenueCatKey") as? String
        return (plist?.isEmpty == false) ? plist : nil
    }

    /// Worker base URL for the production TTS path, resolved in order:
    ///  1. DEBUG/sim — the launch env `READER_WORKER_URL` (export it from your
    ///     gitignored `.env`; see `.env.example`).
    ///  2. Release — the `WorkerBaseURL` Info.plist key (set via a gitignored
    ///     xcconfig; env vars aren't available on device).
    ///  3. A non-functional placeholder, so a fresh clone still builds and the
    ///     public repo ships no live, billable host.
    private static var workerBaseURL: URL {
        var raw: String?
        #if DEBUG
        raw = ProcessInfo.processInfo.environment["READER_WORKER_URL"]
        #endif
        if (raw ?? "").isEmpty {
            raw = Bundle.main.object(forInfoDictionaryKey: "WorkerBaseURL") as? String
        }
        if let raw, !raw.isEmpty, let url = URL(string: raw) { return url }
        return URL(string: "https://your-worker.example.workers.dev")!
    }
}
