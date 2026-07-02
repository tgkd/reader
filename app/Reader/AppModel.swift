import SwiftUI
import ReaderCore
// Disambiguate from `SwiftUI.Document` (added in the iOS 26+ SDK) — the reader's
// Document is always ReaderCore's.
import struct ReaderCore.Document

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

    // MARK: - Import (owned here so it survives Library↔Reader route switches; a view
    // @State import would be torn down mid-run, dropping its banner/errors/result).

    /// Determinate OCR progress for a scanned import; nil when idle or for instant
    /// (text-layer) imports. Drives the Library banner.
    var importProgress: (completed: Int, total: Int)?
    /// Last import failure, surfaced as an alert.
    var importError: String?
    /// An import awaiting the "read N pages with AI?" confirm.
    var pendingImportOCR: PendingImportOCR?
    /// Bumped whenever the shelf changes (import), so the Library list reloads even if
    /// the import finished while the user was elsewhere.
    private(set) var libraryRevision = 0

    /// An import deferred on the OCR confirm. `fallback` is the text we already
    /// extracted (a mixed text+scanned book): saved if the user declines or OCR fails,
    /// so scanned-only pages are the only thing at stake — never the whole book.
    struct PendingImportOCR: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let pageCount: Int
        let recognizer: PDFTextRecognizer
        let fallback: Document?
    }

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
    }

    func cycleTheme() { themeName = themeName.next }
    func open(_ document: Document) { route = .reader(document) }
    func backToLibrary() { route = .library }

    // MARK: - Import flow

    /// Import a picked or "Open in Yomi" file. Copies it into the sandbox inside the
    /// security-scoped window, then extracts off the main actor. Image-only pages are
    /// offered to OCR (subscriber) rather than silently dropped.
    func importFile(_ url: URL) {
        route = .library                 // so the banner/confirm alert (Library chrome) is visible
        importError = nil
        let displayName = url.deletingPathExtension().lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: temp)
            try FileManager.default.copyItem(at: url, to: temp)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            importError = error.localizedDescription
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }

        Task { @MainActor in
            do {
                // Phase 1: local-only extraction (no API spend) — the common case.
                let document = try await Task.detached(priority: .userInitiated) {
                    try await Importer.document(from: temp, ocr: nil)
                }.value
                // Extraction succeeded, but some pages/spine items may have been
                // image-only and skipped. If the user can OCR them, offer to fill them
                // in rather than shipping a book that's silently missing pages.
                let ocr = await services.ocrRecognizer()
                let pages = ocr == nil ? 0 : await Task.detached { Importer.ocrPageCount(for: temp) }.value
                if let ocr, pages > 0 {
                    pendingImportOCR = PendingImportOCR(url: temp, title: displayName,
                                                        pageCount: pages, recognizer: ocr, fallback: document)
                } else {
                    saveImported(document, title: displayName)
                    try? FileManager.default.removeItem(at: temp)
                }
            } catch {
                // Local extraction found nothing. Offer the gated AI path if the book is
                // image-only and the user is a subscriber; else surface the error.
                let ocr = await services.ocrRecognizer()
                let pages = ocr == nil ? 0 : await Task.detached { Importer.ocrPageCount(for: temp) }.value
                guard let ocr, pages > 0 else {
                    importError = error.localizedDescription
                    try? FileManager.default.removeItem(at: temp)
                    return
                }
                pendingImportOCR = PendingImportOCR(url: temp, title: displayName,
                                                    pageCount: pages, recognizer: ocr, fallback: nil)
            }
        }
    }

    /// The user confirmed AI parsing. Re-import WITH OCR (the importers merge text and
    /// recognized pages in reading order), showing the determinate banner.
    func confirmImportOCR(_ p: PendingImportOCR) {
        pendingImportOCR = nil
        Task { @MainActor in
            defer {
                try? FileManager.default.removeItem(at: p.url)
                importProgress = nil
            }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try await Importer.document(from: p.url, ocr: p.recognizer) { done, total in
                        Task { @MainActor in self.importProgress = (done, total) }
                    }
                }.value
                saveImported(document, title: p.title)
            } catch {
                // OCR failed: keep whatever text we already had (mixed book), else report.
                if let fallback = p.fallback { saveImported(fallback, title: p.title) }
                else { importError = error.localizedDescription }
            }
        }
    }

    /// The user declined AI parsing. Save the already-extracted text (a mixed book
    /// keeps its text pages) and drop the temp.
    func cancelImportOCR(_ p: PendingImportOCR) {
        pendingImportOCR = nil
        if let fallback = p.fallback { saveImported(fallback, title: p.title) }
        try? FileManager.default.removeItem(at: p.url)
    }

    private func saveImported(_ document: Document, title: String) {
        var document = document
        document.title = title
        services.library.save(document)
        libraryRevision &+= 1
    }
}
