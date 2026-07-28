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
    /// Narration voice (a subscriber Settings pick). Persisted by id; resolved
    /// against `Voice.catalog` on load so a removed voice falls back to the
    /// default. Mirrored into `AppServices` for cache-key probes and synthesis.
    var narrationVoice: Voice = .george {
        didSet {
            UserDefaults.standard.set(narrationVoice.id, forKey: Self.voiceKey)
            services.narrationVoice = narrationVoice
        }
    }
    private static let themeKey = "reader.themeName"
    private static let fontKey = "reader.readingFont"
    private static let sizeKey = "reader.readingSize"
    private static let orientationKey = "reader.readingOrientation"
    private static let furiganaKey = "reader.showFurigana"
    private static let voiceKey = "reader.narrationVoice"
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
    /// Import succeeded but scanned/image-only pages were omitted (a
    /// non-subscriber's mixed book, or an OCR pass that failed) — surfaced as a
    /// notice, never a silent partial import.
    var importNotice: String?
    /// The omission was the Membership gate rather than a failed OCR pass — only
    /// then does the notice offer a way into Membership (a subscriber whose OCR
    /// failed has nothing to buy).
    var importNoticeNeedsMembership = false
    /// The failure was the Membership gate (a non-subscriber's scanned import) —
    /// the alert then offers a way INTO Membership instead of dead-ending on OK.
    var importErrorNeedsMembership = false
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
        if let raw = defaults.string(forKey: Self.voiceKey),
           let v = Voice.catalog.first(where: { $0.id == raw }) { narrationVoice = v }
        // didSet doesn't fire during init — mirror the loaded voice explicitly.
        services.narrationVoice = narrationVoice
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
        importErrorNeedsMembership = false
        importNotice = nil
        importNoticeNeedsMembership = false
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
                // image-only and skipped. Count OCR candidates regardless of
                // entitlement: a subscriber is offered the fill-in; a non-subscriber
                // keeps the extracted text but gets an explicit "N pages left out"
                // notice — a mixed book must never lose pages silently.
                let ocr = await services.ocrRecognizer()
                let pages = await Task.detached { Importer.ocrPageCount(for: temp) }.value
                if let ocr, pages > 0 {
                    pendingImportOCR = PendingImportOCR(url: temp, title: displayName,
                                                        pageCount: pages, recognizer: ocr, fallback: document)
                } else {
                    saveImported(document, title: displayName)
                    if pages > 0 {
                        importNoticeNeedsMembership = true
                        importNotice = L10n.importPartialBody(pages)
                    }
                    try? FileManager.default.removeItem(at: temp)
                }
            } catch {
                // Local extraction found nothing. Offer the gated AI path if the book is
                // image-only and the user is a subscriber; else surface the error.
                let ocr = await services.ocrRecognizer()
                let pages = ocr == nil ? 0 : await Task.detached { Importer.ocrPageCount(for: temp) }.value
                guard let ocr, pages > 0 else {
                    importErrorNeedsMembership = (error as? ImportError) == .ocrUnavailable
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
            // This confirm can sit on screen indefinitely, so the entitlement that
            // produced `p.recognizer` may be stale — revalidate locally before
            // spending on the paid OCR route (its 403 is only the backstop). A
            // lapsed user keeps the text pages, with the same partial notice a
            // non-subscriber's mixed book gets.
            guard await services.isSubscribed() else {
                if let fallback = p.fallback {
                    saveImported(fallback, title: p.title)
                    importNoticeNeedsMembership = true
                    importNotice = L10n.importPartialBody(p.pageCount)
                } else {
                    importErrorNeedsMembership = true
                    importError = L10n.importOCRUnavailable
                }
                return
            }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try await Importer.document(from: p.url, ocr: p.recognizer) { done, total in
                        Task { @MainActor in self.importProgress = (done, total) }
                    }
                }.value
                saveImported(document, title: p.title)
            } catch {
                // OCR failed after the user approved (and may already have been
                // billed for) the pass. Keep the text we did extract (mixed book),
                // but SAY the scanned pages are missing: saving the fallback
                // silently reports a complete book the user never got.
                if let fallback = p.fallback {
                    saveImported(fallback, title: p.title)
                    importNoticeNeedsMembership = false
                    importNotice = L10n.importPartialOCRFailed(p.pageCount)
                } else {
                    importError = error.localizedDescription
                }
            }
        }
    }

    /// Import pasted text as a book: the same downstream pipeline as a .txt file
    /// (one chapter, split to renderable sub-chapters) with no file involved.
    /// Whitespace-only paste is a no-op — the sheet's Add button is disabled for
    /// it, so there's no error to surface.
    func importPastedText(title: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let chapters = Chapter(title: nil, text: text).splitToRenderable()
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        saveImported(Document(title: "", chapters: chapters),
                     title: name.isEmpty ? Self.defaultPasteTitle(from: trimmed) : name)
    }

    /// Default title for pasted text: its first non-empty line, capped so a
    /// wall of prose doesn't become the row title verbatim.
    static func defaultPasteTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(24))
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
        // library.json is the ONLY copy of an imported book's text, and the store
        // writes it off the main actor — wait for that write to land before the UI
        // reports the import as done (a force-quit would otherwise drop the queued
        // write and the book would be gone on relaunch), and surface a write that
        // genuinely failed instead of swallowing it.
        if !services.library.flush() {
            importErrorNeedsMembership = false
            importError = L10n.importSaveFailed
        }
        libraryRevision &+= 1
    }
}
