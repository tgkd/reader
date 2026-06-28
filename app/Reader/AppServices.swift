import Foundation
import ReaderCore

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
        let fx = FixtureTTSService()
        fixtures = fx

        let store = DiskAudioStore()
        audioStore = store

        let worker = WorkerTTSService(userId: AppServices.userId)
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

        library = DiskLibraryStore(starter: SeedLibrary.documents)

        // Real tap-to-define over the bundled compact jisho DB; fall back to the
        // seeded mock if the DB resource is absent (e.g. a build that skipped
        // scripts/build-compact-dict.sh).
        let sqlite: DictionaryService? = SQLiteDictionaryService()
        dictionary = sqlite ?? MockDictionaryService.seeded()
    }

    /// The RevenueCat appUserID for the Worker's X-User-ID header. Wire this from
    /// the real subscription layer in production; DEBUG can inject one via env.
    private static var userId: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["READER_USER_ID"]
        #else
        return nil
        #endif
    }
}
