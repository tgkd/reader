import SwiftUI
import ReaderCore

/// Top-level UI state: the active theme and which screen is showing. Owns the
/// composed `AppServices`. The reader is a full-screen takeover (its own back
/// affordance), so navigation is a simple route enum rather than a NavigationStack
/// — matching the design's single-component screen switch.
@MainActor
@Observable
final class AppModel {
    /// Active theme. Persisted across launches (the only toggle now lives in the
    /// reader, so it must stick).
    var themeName: ThemeName = .paper {
        didSet { UserDefaults.standard.set(themeName.rawValue, forKey: Self.themeKey) }
    }
    var route: Route = .library
    /// Drives the membership paywall sheet (RevenueCat `PaywallView`).
    var showPaywall = false

    /// Reading-surface preferences (Settings). Persisted across launches so a
    /// chosen font/size sticks; applied to `RubyTextView` only.
    var readingFont: ReadingFont = .mincho {
        didSet { UserDefaults.standard.set(readingFont.rawValue, forKey: Self.fontKey) }
    }
    var readingSize: ReadingSize = .medium {
        didSet { UserDefaults.standard.set(readingSize.rawValue, forKey: Self.sizeKey) }
    }
    /// Writing direction (vertical / horizontal). Global + persisted; the reader's
    /// quick-toggle and the Settings picker both drive it.
    var readingOrientation: Orientation = .tate {
        didSet { UserDefaults.standard.set(readingOrientation.rawValue, forKey: Self.orientationKey) }
    }
    /// Show furigana (reading aids above kanji) in the reader. Global + persisted;
    /// applied to `RubyTextView`. Default on — the audience is learners.
    var showFurigana: Bool = true {
        didSet { UserDefaults.standard.set(showFurigana, forKey: Self.furiganaKey) }
    }
    private static let themeKey = "reader.themeName"
    private static let fontKey = "reader.readingFont"
    private static let sizeKey = "reader.readingSize"
    private static let orientationKey = "reader.readingOrientation"
    private static let furiganaKey = "reader.showFurigana"
    /// Bumped when a purchase/restore completes — the reader observes it to reload
    /// the chapter (now that `reader Pro` is active).
    var entitlementTick = 0

    let services = AppServices()

    enum Route: Equatable {
        case library
        case reader(Document)
    }

    var theme: Theme { themeName.theme }

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.themeKey), let t = ThemeName(rawValue: raw) { themeName = t }
        if let raw = defaults.string(forKey: Self.fontKey), let f = ReadingFont(rawValue: raw) { readingFont = f }
        if let raw = defaults.string(forKey: Self.sizeKey), let s = ReadingSize(rawValue: raw) { readingSize = s }
        if let raw = defaults.string(forKey: Self.orientationKey), let o = Orientation(rawValue: raw) { readingOrientation = o }
        if defaults.object(forKey: Self.furiganaKey) != nil { showFurigana = defaults.bool(forKey: Self.furiganaKey) }

        #if DEBUG
        // Deterministic launch hooks for screenshots (pass via SIMCTL_CHILD_*):
        //   READER_THEME=paper|sepia|night, READER_OPEN=<library index>,
        //   READER_FONT=mincho|gothic|rounded, READER_SIZE=small|medium|large,
        //   READER_FURIGANA=0|1.
        let env = ProcessInfo.processInfo.environment
        if let t = env["READER_THEME"], let name = ThemeName(rawValue: t) { themeName = name }
        if let f = env["READER_FONT"], let rf = ReadingFont(rawValue: f) { readingFont = rf }
        if let s = env["READER_SIZE"], let rs = ReadingSize(rawValue: s) { readingSize = rs }
        if let o = env["READER_ORI"], let ori = Orientation(rawValue: o) { readingOrientation = ori }
        if let v = env["READER_FURIGANA"] { showFurigana = (v == "1") }
        if let raw = env["READER_OPEN"], let i = Int(raw) {
            let docs = services.library.all()
            if docs.indices.contains(i) { route = .reader(docs[i]) }
        }
        // Import a file from a host path and open it (verifies the ingestion path).
        // Scanned PDFs need the Worker OCR (subscriber-gated) — set READER_WORKER_URL.
        if let path = env["READER_IMPORT"] {
            Task { @MainActor in
                let ocr = await services.ocrRecognizer()
                if let doc = try? await Importer.document(from: URL(fileURLWithPath: path), ocr: ocr) {
                    services.library.save(doc)
                    route = .reader(doc)
                }
            }
        }
        // Force-show the paywall for local testing (the sim's appUserID is already
        // entitled, so the real gate wouldn't trigger).
        if env["READER_PAYWALL"] == "1" { showPaywall = true }
        #endif
    }

    func cycleTheme() { themeName = themeName.next }
    func open(_ document: Document) { route = .reader(document) }
    func backToLibrary() { route = .library }
}
