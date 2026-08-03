import Foundation
import ReaderCore
import RevenueCat

@MainActor
final class AppServices {
    let tokenizerWorker = TokenizerWorker()

    let tts: TTSService
    let synthesis: SynthesisCoordinator
    let synthesisStream = SynthesisStream()
    var measuredSecondsPerChar: Double? {
        get {
            let stored = UserDefaults.standard.double(forKey: Self.rateKey(narrationVoice))
            return stored > 0 ? stored : nil
        }
        set {
            guard let newValue, (0.1...0.5).contains(newValue) else { return }
            UserDefaults.standard.set(newValue, forKey: Self.rateKey(narrationVoice))
        }
    }

    private static func rateKey(_ voice: Voice) -> String { "measuredSecondsPerChar.\(voice.id)" }
    let fixtures: FixtureTTSService
    let audioStore: GeneratedAudioStore
    let library: LibraryStore
    let dictionary: DictionaryService

    init() {
        fixtures = FixtureTTSService()

        let store = DiskAudioStore()
        audioStore = store

        let stream = synthesisStream
        let worker = WorkerTTSService(
            baseURL: AppServices.workerBaseURL, userId: { AppServices.userId },
            onChunk: { key, audio, alignment in
                stream.publish(key, audio: audio, alignment: alignment)
            })
        tts = ChunkingTTSService(inner: worker, store: store)
        synthesis = SynthesisCoordinator(tts: tts, store: store)

        library = DiskLibraryStore(starter: [])

        let sqlite: DictionaryService? = SQLiteDictionaryService()
        dictionary = sqlite ?? MockDictionaryService.seeded()
    }

    var narrationVoice: Voice = .shizuka {
        didSet { if narrationVoice != oldValue { contentKeyCache.removeAll() } }
    }

    private var contentKeyCache: [Document.ID: [ContentKey]] = [:]

    func firstChapterKeys(for document: Document) -> [ContentKey] {
        if let cached = contentKeyCache[document.id] { return cached }
        let keys = SynthesisRequest(text: document.chapters.first?.text ?? "",
                                    voice: narrationVoice).cacheKeyCandidates
        contentKeyCache[document.id] = keys
        return keys
    }

    func invalidateKey(for id: Document.ID) { contentKeyCache[id] = nil }

    static let entitlementID = "reader Pro"

    static func configureRevenueCat() {
        guard !Purchases.isConfigured, let key = revenueCatKey, !key.isEmpty else { return }
        Purchases.configure(withAPIKey: key)
    }

    nonisolated static func purgeableTexts(of document: Document, in all: [Document]) -> [String] {
        let stillReferenced = Set(
            all.filter { $0.id != document.id }
               .flatMap(\.chapters)
               .map { Normalize.nfkc($0.text) }
        )
        var seen = Set<String>()
        return document.chapters
            .map { Normalize.nfkc($0.text) }
            .filter { !stillReferenced.contains($0) && seen.insert($0).inserted }
    }

    func purgeAudio(for document: Document) async {
        for normalized in Self.purgeableTexts(of: document, in: library.all()) {
            let segments = Chunker.split(normalized, maxChars: SynthesisLimits.maxRequestChars)
            for voice in Voice.catalog {
                for key in SynthesisRequest(text: normalized, voice: voice).cacheKeyCandidates {
                    await synthesis.cancelAndWait(key)
                    audioStore.remove(key)
                }
                if segments.count > 1 {
                    for segment in segments {
                        for key in SynthesisRequest(text: segment, voice: voice).cacheKeyCandidates {
                            audioStore.remove(key)
                        }
                    }
                }
            }
        }
    }

    func isSubscribed() async -> Bool {
        guard Purchases.isConfigured else { return false }
        let info = try? await Purchases.shared.customerInfo()
        return info?.entitlements[AppServices.entitlementID]?.isActive == true
    }

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

    func ocrRecognizer() async -> PDFTextRecognizer? {
        guard await isSubscribed() else { return nil }
        return WorkerOCRService(baseURL: AppServices.workerBaseURL, userId: AppServices.userId,
                                inFlight: ocrInFlight)
    }

    private let ocrInFlight = OCRInFlightPages()

    nonisolated private static var userId: String? {
        Purchases.isConfigured ? Purchases.shared.appUserID : nil
    }

    private static var revenueCatKey: String? {
        let plist = Bundle.main.object(forInfoDictionaryKey: "RevenueCatKey") as? String
        return (plist?.isEmpty == false) ? plist : nil
    }

    private static var workerBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "WorkerBaseURL") as? String
        if let raw, let url = URL(string: raw), url.host?.isEmpty == false { return url }
        return URL(string: "https://api.thetango.org")!
    }
}
