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
    /// Use the Worker's higher-quality OCR for scanned-PDF import (subscribers only;
    /// uploads page images to a third-party model). Default OFF — the on-device
    /// Vision engine is the default. Persisted so the choice sticks.
    var enhancedOCR: Bool = false {
        didSet { UserDefaults.standard.set(enhancedOCR, forKey: Self.enhancedOCRKey) }
    }
    private static let themeKey = "reader.themeName"
    private static let fontKey = "reader.readingFont"
    private static let sizeKey = "reader.readingSize"
    private static let enhancedOCRKey = "reader.enhancedOCR"
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
        enhancedOCR = defaults.bool(forKey: Self.enhancedOCRKey)

        #if DEBUG
        // Deterministic launch hooks for screenshots (pass via SIMCTL_CHILD_*):
        //   READER_THEME=paper|sepia|night, READER_OPEN=<library index>,
        //   READER_FONT=mincho|gothic|rounded, READER_SIZE=small|medium|large.
        let env = ProcessInfo.processInfo.environment
        if let t = env["READER_THEME"], let name = ThemeName(rawValue: t) { themeName = name }
        if let f = env["READER_FONT"], let rf = ReadingFont(rawValue: f) { readingFont = rf }
        if let s = env["READER_SIZE"], let rs = ReadingSize(rawValue: s) { readingSize = rs }
        if let raw = env["READER_OPEN"], let i = Int(raw) {
            let docs = services.library.all()
            if docs.indices.contains(i) { route = .reader(docs[i]) }
        }
        if env["READER_ENHANCED_OCR"] == "1" { enhancedOCR = true }
        // Import a file from a host path and open it (verifies the ingestion path).
        // Uses on-device Vision OCR explicitly so sim verification stays offline.
        if let path = env["READER_IMPORT"] {
            Task { @MainActor in
                if let doc = try? await Importer.document(from: URL(fileURLWithPath: path),
                                                          ocr: VisionOCRService()) {
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
