import SwiftUI
import ReaderCore
// Disambiguate from `SwiftUI.Document` (added in the iOS 26+ SDK) — the reader's
// Document is always ReaderCore's.
import struct ReaderCore.Document

/// One visible import job. Progress is phase-local rather than a fabricated
/// end-to-end percentage: page/spine parsing and OCR have real totals, while file
/// preparation, inspection, and the durable save are honestly indeterminate.
struct ImportActivity: Identifiable, Equatable {
    enum Phase: Equatable {
        case preparing
        case parsing
        case inspecting
        case awaitingOCR
        case recognizing
        case saving
        case completed
    }

    let id: UUID
    let fileName: String
    var phase: Phase
    var completed: Int?
    var total: Int?
    /// Set once the user has approved the paid OCR pass. It is NOT enough to gate
    /// on `phase`: the confirmed re-import starts in `.parsing` (the local page
    /// walk that precedes the first `/pdf/ocr` window), so a phase-only rule hands
    /// the user an X over work that is about to be billed.
    var isPaid: Bool = false

    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    /// Paid OCR is deliberately not cancelled mid-pass: requests already accepted
    /// by the Worker may already be billed, and their responses must reach the page
    /// cache. Local work can be dismissed safely.
    var canCancel: Bool {
        guard !isPaid else { return false }
        switch phase {
        case .preparing, .parsing, .inspecting: return true
        case .awaitingOCR, .recognizing, .saving, .completed: return false
        }
    }
}

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

    /// The import capsule's current job. Owned here (rather than Library @State) so
    /// parsing survives route/view changes and "Open in Yomi" follows the same flow.
    private(set) var importActivity: ImportActivity?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importTaskID: UUID?
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
        let id: UUID
        let url: URL
        let title: String
        let fileName: String
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
        // A job kept on screen only for its completion checkmark is cosmetic — it
        // must not refuse the next file (two books shared back-to-back land inside
        // that window). Refusal also does NOT route: yanking a reader out of their
        // chapter to say "busy" costs them the reading surface for nothing; the
        // alert is Library chrome and surfaces the next time they land there.
        if let active = importActivity, active.phase != .completed {
            importErrorNeedsMembership = false
            importError = L10n.importBusy
            return
        }
        route = .library                 // so the capsule/confirm alert (Library chrome) is visible
        importError = nil
        importErrorNeedsMembership = false
        importNotice = nil
        importNoticeNeedsMembership = false
        let displayName = url.deletingPathExtension().lastPathComponent
        let fileName = url.lastPathComponent
        let jobID = UUID()
        importActivity = ImportActivity(id: jobID, fileName: fileName,
                                        phase: .preparing, completed: nil, total: nil)
        let scoped = url.startAccessingSecurityScopedResource()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)

        let task = Task { @MainActor [weak self] in
            guard let self else {
                if scoped { url.stopAccessingSecurityScopedResource() }
                return
            }
            // A copy failure is terminal and must stay terminal. Folding it into the
            // shared catch below would run an entitlement lookup and an OCR-candidate
            // scan against a file that was never created, and only then report the
            // original error.
            do {
                // The picker may hand back a large iCloud/File Provider item. Copy
                // outside the main actor so the newly-mounted capsule can render.
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: temp)
                    try FileManager.default.copyItem(at: url, to: temp)
                }.value
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: temp)
                if self.importActivity?.id == jobID { self.importActivity = nil }
                if !(error is CancellationError) {
                    self.importErrorNeedsMembership = false
                    self.importError = error.localizedDescription
                }
                self.clearImportTask(jobID)
                return
            }
            if scoped { url.stopAccessingSecurityScopedResource() }

            do {
                try Task.checkCancellation()

                // Phase 1: local-only extraction (no API spend) — the common case.
                self.updateImport(jobID, phase: .parsing)
                // `Task.detached` does not inherit cancellation and `await .value` is
                // not a cancellation point, so without this handler the X would only
                // hide the capsule while the parse ran to completion in the
                // background — and a second import could start alongside it.
                let parse = Task.detached(priority: .userInitiated) { [weak self] in
                    try await Importer.document(
                        from: temp,
                        ocr: nil,
                        onParsingProgress: { done, total in
                            Task { @MainActor [weak self] in
                                self?.updateImport(jobID, phase: .parsing,
                                                   completed: done, total: total)
                            }
                        }
                    )
                }
                let document = try await withTaskCancellationHandler {
                    try await parse.value
                } onCancel: {
                    parse.cancel()
                }
                try Task.checkCancellation()
                // Extraction succeeded, but some pages/spine items may have been
                // image-only and skipped. Count OCR candidates regardless of
                // entitlement: a subscriber is offered the fill-in; a non-subscriber
                // keeps the extracted text but gets an explicit "N pages left out"
                // notice — a mixed book must never lose pages silently.
                self.updateImport(jobID, phase: .inspecting)
                let ocr = await services.ocrRecognizer()
                let pages = await Task.detached { Importer.ocrPageCount(for: temp) }.value
                try Task.checkCancellation()
                // Publishing the confirm has to re-check ownership: the awaits above
                // are exactly where the user hits X, and an alert whose job no longer
                // owns `importActivity` cannot be dismissed (both handlers bail on the
                // same identity guard).
                guard importActivity?.id == jobID else {
                    try? FileManager.default.removeItem(at: temp)
                    clearImportTask(jobID)
                    return
                }
                if let ocr, pages > 0 {
                    pendingImportOCR = PendingImportOCR(id: jobID, url: temp, title: displayName,
                                                        fileName: fileName,
                                                        pageCount: pages, recognizer: ocr, fallback: document)
                    updateImport(jobID, phase: .awaitingOCR)
                } else {
                    // Only disclose the omitted pages if the book actually landed —
                    // a "N pages left out" notice on a failed save reads as success.
                    if await finishImport(document, title: displayName, jobID: jobID), pages > 0 {
                        importNoticeNeedsMembership = true
                        importNotice = L10n.importPartialBody(pages)
                    }
                    try? FileManager.default.removeItem(at: temp)
                }
            } catch {
                // Local extraction found nothing. Offer the gated AI path if the book is
                // image-only and the user is a subscriber; else surface the error.
                if error is CancellationError {
                    try? FileManager.default.removeItem(at: temp)
                    clearImportTask(jobID)
                    return
                }
                guard importActivity?.id == jobID else {
                    try? FileManager.default.removeItem(at: temp)
                    clearImportTask(jobID)
                    return
                }
                updateImport(jobID, phase: .inspecting)
                let ocr = await services.ocrRecognizer()
                let pages = ocr == nil ? 0 : await Task.detached { Importer.ocrPageCount(for: temp) }.value
                guard let ocr, pages > 0 else {
                    importActivity = nil
                    importErrorNeedsMembership = (error as? ImportError) == .ocrUnavailable
                    importError = error.localizedDescription
                    try? FileManager.default.removeItem(at: temp)
                    clearImportTask(jobID)
                    return
                }
                // Same re-check as the success path — `.inspecting` shows a live X and
                // both awaits above can outlive it.
                guard importActivity?.id == jobID else {
                    try? FileManager.default.removeItem(at: temp)
                    clearImportTask(jobID)
                    return
                }
                pendingImportOCR = PendingImportOCR(id: jobID, url: temp, title: displayName,
                                                    fileName: fileName,
                                                    pageCount: pages, recognizer: ocr, fallback: nil)
                updateImport(jobID, phase: .awaitingOCR)
            }
            self.clearImportTask(jobID)
        }
        importTask = task
        importTaskID = jobID
    }

    /// The user confirmed AI parsing. Re-import WITH OCR (the importers merge text and
    /// recognized pages in reading order), showing the determinate banner.
    func confirmImportOCR(_ p: PendingImportOCR) {
        // Clear the alert BEFORE the ownership guard. Bailing out with it still set
        // leaves `showOCRConfirm` reading non-nil, so SwiftUI re-presents an alert
        // whose every button returns on this same guard — an unescapable modal.
        pendingImportOCR = nil
        guard importActivity?.id == p.id else {
            try? FileManager.default.removeItem(at: p.url)
            return
        }
        // Everything from here may be billed, including the local page walk that
        // precedes the first OCR window — withdraw the X for the rest of the job.
        markImportPaid(p.id)
        updateImport(p.id, phase: .parsing)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: p.url)
            }
            // This confirm can sit on screen indefinitely, so the entitlement that
            // produced `p.recognizer` may be stale — revalidate locally before
            // spending on the paid OCR route (its 403 is only the backstop). A
            // lapsed user keeps the text pages, with the same partial notice a
            // non-subscriber's mixed book gets.
            guard await services.isSubscribed() else {
                if let fallback = p.fallback {
                    if await finishImport(fallback, title: p.title, jobID: p.id) {
                        importNoticeNeedsMembership = true
                        importNotice = L10n.importPartialBody(p.pageCount)
                    }
                } else {
                    importActivity = nil
                    importErrorNeedsMembership = true
                    importError = L10n.importOCRUnavailable
                }
                clearImportTask(p.id)
                return
            }
            do {
                let document = try await Task.detached(priority: .userInitiated) { [weak self] in
                    // No parsing callback here on purpose: this pass counts ALL pages
                    // while the OCR callback below counts only the scanned ones, so
                    // driving both into one bar fills it to 100% and snaps it back to
                    // 0%. The local walk stays indeterminate until recognition starts.
                    try await Importer.document(
                        from: p.url,
                        ocr: p.recognizer,
                        onProgress: { done, total in
                            Task { @MainActor [weak self] in
                                self?.updateImport(p.id, phase: .recognizing,
                                                   completed: done, total: total)
                            }
                        }
                    )
                }.value
                await finishImport(document, title: p.title, jobID: p.id)
            } catch {
                // OCR failed after the user approved (and may already have been
                // billed for) the pass. Keep the text we did extract (mixed book),
                // but SAY the scanned pages are missing: saving the fallback
                // silently reports a complete book the user never got.
                if let fallback = p.fallback {
                    if await finishImport(fallback, title: p.title, jobID: p.id) {
                        importNoticeNeedsMembership = false
                        importNotice = L10n.importPartialOCRFailed(p.pageCount)
                    }
                } else {
                    importActivity = nil
                    importError = error.localizedDescription
                }
            }
            self.clearImportTask(p.id)
        }
        importTask = task
        importTaskID = p.id
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
        // Cleared before the guard for the same reason as `confirmImportOCR`.
        pendingImportOCR = nil
        guard importActivity?.id == p.id else {
            try? FileManager.default.removeItem(at: p.url)
            return
        }
        if let fallback = p.fallback {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await finishImport(fallback, title: p.title, jobID: p.id)
                try? FileManager.default.removeItem(at: p.url)
                clearImportTask(p.id)
            }
            importTask = task
            importTaskID = p.id
        } else {
            importActivity = nil
            try? FileManager.default.removeItem(at: p.url)
        }
    }

    /// Explicit X from the capsule. Only local phases expose it; OCR deliberately
    /// drains so accepted paid responses can be cached.
    func cancelImport() {
        guard let activity = importActivity, activity.canCancel else { return }
        importActivity = nil
        if importTaskID == activity.id {
            importTask?.cancel()
            importTask = nil
            importTaskID = nil
        }
    }

    private func updateImport(_ id: UUID, phase: ImportActivity.Phase,
                              completed: Int? = nil, total: Int? = nil) {
        guard var activity = importActivity, activity.id == id else { return }
        // A total of 0 means "this stage has no measurable size" — keep the bar
        // indeterminate rather than rendering a "0 / 0" counter.
        let completed = (total ?? 0) > 0 ? completed : nil
        let total = (total ?? 0) > 0 ? total : nil
        // Progress callbacks hop back from detached work. Ignore a late callback
        // after the owning job has already advanced to a later structural phase.
        if completed != nil {
            if phase == .parsing, activity.phase != .parsing { return }
            if phase == .recognizing,
               activity.phase != .parsing, activity.phase != .recognizing { return }
            // Each callback hops the main actor as its own unstructured task, and
            // the runtime does not order those relative to one another. Within one
            // determinate run the count must never walk backwards.
            if activity.phase == phase, activity.total == total,
               let previous = activity.completed, let now = completed, now < previous { return }
        }
        activity.phase = phase
        activity.completed = completed
        activity.total = total
        importActivity = activity
    }

    /// Withdraw the cancel affordance for the rest of a job the user has paid for.
    private func markImportPaid(_ id: UUID) {
        guard var activity = importActivity, activity.id == id else { return }
        activity.isPaid = true
        importActivity = activity
    }

    /// Save and show the completion checkmark. Returns whether the book actually
    /// landed, so callers only disclose omitted pages for a book that exists.
    @discardableResult
    private func finishImport(_ document: Document, title: String, jobID: UUID) async -> Bool {
        guard importActivity?.id == jobID else { return false }
        updateImport(jobID, phase: .saving)
        // Let SwiftUI commit the phase change before the flush barrier.
        await Task.yield()
        guard saveImported(document, title: title) else {
            importActivity = nil
            return false
        }
        updateImport(jobID, phase: .completed, completed: 1, total: 1)
        // Hold the checkmark, but do NOT make the caller wait for it — a partial
        // import notice has to land with the result, not a second behind it.
        Task { @MainActor [weak self] in
            try? await Task<Never, Never>.sleep(nanoseconds: 850_000_000)
            guard let self, self.importActivity?.id == jobID else { return }
            self.importActivity = nil
        }
        return true
    }

    private func clearImportTask(_ id: UUID) {
        guard importTaskID == id else { return }
        importTask = nil
        importTaskID = nil
    }

    @discardableResult
    private func saveImported(_ document: Document, title: String) -> Bool {
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
            libraryRevision &+= 1
            return false
        }
        libraryRevision &+= 1
        return true
    }
}
