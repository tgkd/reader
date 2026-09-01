import SwiftUI
import ReaderCore
import struct ReaderCore.Document

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
    var isPaid: Bool = false

    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var canCancel: Bool {
        guard !isPaid else { return false }
        switch phase {
        case .preparing, .parsing, .inspecting: return true
        case .awaitingOCR, .recognizing, .saving, .completed: return false
        }
    }
}

@MainActor
@Observable
final class AppModel {
    var themeName: ThemeName = .paper {
        didSet { UserDefaults.standard.set(themeName.rawValue, forKey: Self.themeKey) }
    }
    var route: Route = .library
    var showPaywall = false

    var readingFont: ReadingFont = .mincho {
        didSet { UserDefaults.standard.set(readingFont.rawValue, forKey: Self.fontKey) }
    }
    var readingSize: ReadingSize = .medium {
        didSet { UserDefaults.standard.set(readingSize.rawValue, forKey: Self.sizeKey) }
    }
    var readingOrientation: Orientation = .yoko {
        didSet { UserDefaults.standard.set(readingOrientation.rawValue, forKey: Self.orientationKey) }
    }
    private(set) var orientationOverrides: [String: Orientation] = [:] {
        didSet {
            let raw = orientationOverrides.mapValues(\.rawValue)
            UserDefaults.standard.set(raw, forKey: Self.orientationOverrideKey)
        }
    }

    func readingOrientation(for document: Document) -> Orientation {
        orientationOverrides[document.id.uuidString] ?? readingOrientation
    }

    func toggleReadingOrientation(for document: Document) {
        let next: Orientation = readingOrientation(for: document) == .tate ? .yoko : .tate
        orientationOverrides[document.id.uuidString] = next
        readingOrientation = next
    }
    var showFurigana: Bool = true {
        didSet { UserDefaults.standard.set(showFurigana, forKey: Self.furiganaKey) }
    }
    var narrationVoice: Voice = .shizuka {
        didSet {
            UserDefaults.standard.set(narrationVoice.id, forKey: Self.voiceKey)
            services.narrationVoice = narrationVoice
        }
    }
    private static let themeKey = "reader.themeName"
    private static let fontKey = "reader.readingFont"
    private static let sizeKey = "reader.readingSize"
    private static let orientationKey = "reader.readingOrientation"
    private static let orientationOverrideKey = "reader.orientationOverrides"
    private static let furiganaKey = "reader.showFurigana"
    private static let voiceKey = "reader.narrationVoice"
    private static let starterSeedKey = "reader.starterSeedPending"
    var entitlementTick = 0

    let services = AppServices()

    private(set) var importActivity: ImportActivity?
    @ObservationIgnored private var importTask: Task<Void, Never>?
    @ObservationIgnored private var importTaskID: UUID?
    @ObservationIgnored private var didSeedStarterBooks = false
    var importError: String?
    var importNotice: String?
    var importNoticeNeedsMembership = false
    var importErrorNeedsMembership = false
    var pendingImportOCR: PendingImportOCR?
    private(set) var libraryRevision = 0

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
        if let raw = defaults.dictionary(forKey: Self.orientationOverrideKey) as? [String: String] {
            orientationOverrides = raw.compactMapValues(Orientation.init(rawValue:))
        }
        if defaults.object(forKey: Self.furiganaKey) != nil { showFurigana = defaults.bool(forKey: Self.furiganaKey) }
        if let raw = defaults.string(forKey: Self.voiceKey),
           let v = services.voiceCatalog.voice(id: raw) { narrationVoice = v }
        services.narrationVoice = narrationVoice
    }

    func cycleTheme() { themeName = themeName.next }
    func open(_ document: Document) { route = .reader(services.library.current(document)) }
    func backToLibrary() { route = .library }

    func importFile(_ url: URL) {
        if let active = importActivity, active.phase != .completed {
            importErrorNeedsMembership = false
            importError = L10n.importBusy
            return
        }
        route = .library
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
            do {
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

                self.updateImport(jobID, phase: .parsing)
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
                self.updateImport(jobID, phase: .inspecting)
                let ocr = await services.ocrRecognizer()
                let pages = await Task.detached { Importer.ocrPageCount(for: temp) }.value
                try Task.checkCancellation()
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
                    if await finishImport(document, title: displayName, jobID: jobID), pages > 0 {
                        importNoticeNeedsMembership = true
                        importNotice = L10n.importPartialBody(pages)
                    }
                    try? FileManager.default.removeItem(at: temp)
                }
            } catch {
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

    func confirmImportOCR(_ p: PendingImportOCR) {
        pendingImportOCR = nil
        guard importActivity?.id == p.id else {
            try? FileManager.default.removeItem(at: p.url)
            return
        }
        markImportPaid(p.id)
        updateImport(p.id, phase: .parsing)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: p.url)
            }
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

    func importPastedText(title: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let chapters = Chapter(title: nil, text: text).splitToRenderable()
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        saveImported(Document(title: "", chapters: chapters),
                     title: name.isEmpty ? Self.defaultPasteTitle(from: trimmed) : name)
    }

    func seedStarterBooksIfNeeded() async {
        guard !didSeedStarterBooks else { return }
        let defaults = UserDefaults.standard
        if services.libraryWasCreated, defaults.object(forKey: Self.starterSeedKey) == nil {
            defaults.set(StarterLibrary.books.map(\.id), forKey: Self.starterSeedKey)
        }
        guard var pending = defaults.array(forKey: Self.starterSeedKey) as? [String],
              !pending.isEmpty else { return }
        didSeedStarterBooks = true
        for book in StarterLibrary.books where pending.contains(book.id) {
            guard let url = StarterLibrary.url(for: book),
                  let document = try? await Self.loadStarter(url) else { continue }
            let needsSave = !libraryContains(book)
            if needsSave { services.library.save(document) }
            guard services.library.flush() else { continue }
            if needsSave { libraryRevision &+= 1 }
            pending.removeAll { $0 == book.id }
            defaults.set(pending, forKey: Self.starterSeedKey)
        }
    }

    func importStarterBook(_ book: StarterLibrary.Book) async {
        guard let url = StarterLibrary.url(for: book) else { return }
        importError = nil
        importErrorNeedsMembership = false
        do {
            let document = try await Self.loadStarter(url)
            guard !libraryContains(book) else { return }
            saveImported(document, title: book.title)
        } catch {
            importErrorNeedsMembership = false
            importError = error.localizedDescription
        }
    }

    func libraryContains(_ book: StarterLibrary.Book) -> Bool {
        services.library.all().contains { $0.title == book.title }
    }

    private static func loadStarter(_ url: URL) async throws -> Document {
        try await Task.detached(priority: .userInitiated) {
            try await Importer.document(from: url, ocr: nil)
        }.value
    }

    static func defaultPasteTitle(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(firstLine.trimmingCharacters(in: .whitespaces).prefix(24))
    }

    func cancelImportOCR(_ p: PendingImportOCR) {
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
        let completed = (total ?? 0) > 0 ? completed : nil
        let total = (total ?? 0) > 0 ? total : nil
        if completed != nil {
            if phase == .parsing, activity.phase != .parsing { return }
            if phase == .recognizing,
               activity.phase != .parsing, activity.phase != .recognizing { return }
            if activity.phase == phase, activity.total == total,
               let previous = activity.completed, let now = completed, now < previous { return }
        }
        activity.phase = phase
        activity.completed = completed
        activity.total = total
        importActivity = activity
    }

    private func markImportPaid(_ id: UUID) {
        guard var activity = importActivity, activity.id == id else { return }
        activity.isPaid = true
        importActivity = activity
    }

    @discardableResult
    private func finishImport(_ document: Document, title: String, jobID: UUID) async -> Bool {
        guard importActivity?.id == jobID else { return false }
        updateImport(jobID, phase: .saving)
        await Task.yield()
        guard saveImported(document, title: title) else {
            importActivity = nil
            return false
        }
        updateImport(jobID, phase: .completed, completed: 1, total: 1)
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
        if document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.title = title
        }
        services.library.save(document)
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
