import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

/// The Library / home screen: the 読み wordmark, theme + add controls, and a
/// quiet list of texts with author, cached marker, status, and progress bar.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = LibraryModel()
    @State private var importing = false
    @State private var importError: String?
    @State private var showingSettings = false
    /// Row the user swiped to delete, pending the confirmation alert.
    @State private var pendingDelete: LibraryModel.Item?
    /// A subscriber import that found no extractable text but has OCR-able image pages,
    /// awaiting the "read N pages with AI?" confirm. Holds the temp copy alive across the
    /// prompt; the temp is removed when the prompt resolves either way.
    @State private var pendingOCR: PendingOCR?

    /// An import deferred on the OCR confirm prompt (see `pendingOCR`).
    private struct PendingOCR: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let pageCount: Int
        let recognizer: PDFTextRecognizer
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 22)
            if model.items.isEmpty {
                emptyState
            } else {
                // A plain List (chrome stripped to keep the custom row look) so each
                // row gets native swipe-to-delete; the destructive action routes
                // through a confirmation alert rather than deleting on the swipe.
                List {
                    ForEach(model.items) { item in
                        row(item)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(theme.bg)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = item } label: {
                                    Label(L10n.libraryDelete, systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
            }
        }
        .onAppear {
            model.load(app.services)
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.epub, .pdf, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert(L10n.importFailedTitle, isPresented: showImportError) {
            Button(L10n.commonOK, role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .alert(L10n.libraryDeleteTitle, isPresented: showDeleteConfirm, presenting: pendingDelete) { item in
            Button(L10n.libraryDelete, role: .destructive) { model.delete(item.document, app.services) }
            Button(L10n.commonCancel, role: .cancel) {}
        } message: { item in
            Text(L10n.libraryDeleteBody(item.document.title))
        }
        .alert(L10n.importOCRConfirmTitle, isPresented: showOCRConfirm, presenting: pendingOCR) { p in
            Button(L10n.importOCRConfirmAction) { runOCRImport(p) }
            Button(L10n.commonCancel, role: .cancel) { try? FileManager.default.removeItem(at: p.url) }
        } message: { p in
            Text(L10n.importOCRConfirmBody(p.pageCount))
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .overlay(alignment: .bottom) {
            if let p = model.importProgress { importBanner(p) }
        }
    }

    /// Determinate banner while a scanned PDF is being OCR'd (the only slow import
    /// path; text-layer imports are instant and show nothing).
    private func importBanner(_ p: (completed: Int, total: Int)) -> some View {
        Text(L10n.importRecognizing(p.completed, p.total))
            .font(.system(size: 12.5).monospacedDigit()).foregroundStyle(theme.bg)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(theme.ink))
            .padding(.bottom, 28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var showImportError: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    private var showDeleteConfirm: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var showOCRConfirm: Binding<Bool> {
        Binding(get: { pendingOCR != nil }, set: { if !$0 { pendingOCR = nil } })
    }

    /// Import the picked file (EPUB / PDF / .txt) into the library. The file is
    /// copied into the sandbox inside the security-scoped window (fast), then
    /// parsed off the main actor so a large EPUB/PDF doesn't freeze the UI; the new
    /// row appears when parsing finishes.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        // Title from the ORIGINAL file name — the temp copy below is UUID-prefixed,
        // so deriving the title from it would name every import after the temp file.
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
            // Phase 1: local-only extraction — no API spend, handles the common case
            // (born-digital EPUB/PDF, .txt). OCR is deliberately withheld here.
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try await Importer.document(from: temp, ocr: nil)
                }.value
                save(document, title: displayName)
                try? FileManager.default.removeItem(at: temp)
            } catch {
                // Local extraction found nothing. For a non-subscriber (no OCR engine),
                // or a file OCR can't help, surface the local error as-is. For a
                // subscriber whose book is image-only, offer the gated AI path.
                let ocr = await app.services.ocrRecognizer()
                let pages = ocr == nil ? 0
                    : await Task.detached { Importer.ocrPageCount(for: temp) }.value
                guard let ocr, pages > 0 else {
                    importError = error.localizedDescription
                    try? FileManager.default.removeItem(at: temp)
                    return
                }
                pendingOCR = PendingOCR(url: temp, title: displayName, pageCount: pages, recognizer: ocr)
            }
        }
    }

    /// Phase 2: the user confirmed AI parsing of an image-only book. Run OCR (with the
    /// determinate banner) and save; the temp copy is released either way.
    private func runOCRImport(_ p: PendingOCR) {
        Task { @MainActor in
            let model = self.model
            defer {
                try? FileManager.default.removeItem(at: p.url)
                model.importProgress = nil
            }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try await Importer.document(from: p.url, ocr: p.recognizer) { done, total in
                        Task { @MainActor in model.importProgress = (done, total) }
                    }
                }.value
                save(document, title: p.title)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    /// Title the parsed document, persist it, and refresh the shelf.
    private func save(_ document: Document, title: String) {
        var document = document
        document.title = title
        app.services.library.save(document)
        model.load(app.services)
    }

    /// Shown when no books have been imported yet (the default on a fresh install,
    /// now that the sample shelf is dev-only). Keeps first run from looking broken.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(L10n.libraryEmptyTitle)
                .font(Mincho.font(18)).foregroundStyle(theme.ink)
            Text(L10n.libraryEmptyBody)
                .font(.system(size: 13)).foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 9, height: 9)
                Text(L10n.wordmark).font(Mincho.font(22)).foregroundStyle(theme.ink).tracking(3)
            }
            Spacer()
            HStack(spacing: 10) {
                IconButton(systemImage: "star.circle",
                           foreground: theme.muted, label: L10n.a11yMembership) { app.showPaywall = true }
                IconButton(systemImage: "gearshape",
                           foreground: theme.muted, label: L10n.a11ySettings) { showingSettings = true }
                IconButton(systemImage: "plus", font: .system(size: 18),
                           foreground: theme.ink, label: L10n.a11yAdd) { importing = true }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func row(_ item: LibraryModel.Item) -> some View {
        Button { app.open(item.document) } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.document.title)
                            .font(app.readingFont.font(19)).foregroundStyle(theme.ink).tracking(0.5)
                        Text(item.document.author ?? "")
                            .font(.system(size: 12.5)).foregroundStyle(theme.muted).tracking(0.5)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 9) {
                        if item.cached {
                            Text("↓")
                                .font(.system(size: 10)).foregroundStyle(theme.muted)
                                .frame(width: 17, height: 17)
                                .overlay(Circle().stroke(theme.muted, lineWidth: 1))
                                .accessibilityLabel(L10n.a11yAudioCached)
                        }
                        Text(item.statusLabel)
                            .font(.system(size: 11.5)).foregroundStyle(theme.muted).monospacedDigit()
                    }
                    .padding(.top, 3)
                }
                progressBar(item.document.progress.fraction)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hair).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func progressBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.soft)
                Capsule().fill(theme.accent)
                    .frame(width: max(0, geo.size.width * fraction))
                    .opacity(fraction <= 0 ? 0 : 1)
            }
        }
        .frame(height: 3)
    }
}
