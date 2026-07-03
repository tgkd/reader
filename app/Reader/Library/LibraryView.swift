import SwiftUI
import UniformTypeIdentifiers
import ReaderCore
import struct ReaderCore.Document   // disambiguate from SwiftUI.Document

/// The Library / home screen: the 読み wordmark, theme + add controls, and a
/// quiet list of texts with author, cached marker, status, and progress bar.
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = LibraryModel()
    @State private var importing = false
    @State private var showingSettings = false
    /// Row the user swiped to delete, pending the confirmation alert.
    @State private var pendingDelete: LibraryModel.Item?
    /// Hides the membership (paywall) button once subscribed — it's purely an
    /// upsell entry; a lapsed or reinstalled user sees it again (and Restore
    /// lives on the paywall it opens).
    @State private var isSubscribed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.items.isEmpty {
                emptyState
            } else {
                // A plain List with its native row chrome (insets, separators,
                // swipe-to-delete); the destructive action routes through a
                // confirmation alert rather than deleting on the swipe.
                List {
                    ForEach(model.items) { item in
                        // Clear, not theme.bg: RootView already paints the themed
                        // background, and an opaque row slices the glass header's
                        // soft shadow with a hard edge where the list begins.
                        row(item)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { pendingDelete = item } label: {
                                    Label(L10n.libraryDelete, systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                // Claim the remaining height explicitly. Without this the List sizes to
                // its content inside the VStack and overflows the screen without
                // scrolling once there are more rows than fit (was latent when the
                // shelf fit on one screen).
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.load(app.services)
        }
        .task { isSubscribed = await app.services.isSubscribed() }
        // A purchase/restore just completed — drop the upsell button live.
        .onChange(of: app.entitlementTick) { _, _ in
            Task { isSubscribed = await app.services.isSubscribed() }
        }
        // The shelf changed (an import finished, possibly while the user was in the
        // reader) — reload so the new book appears without waiting for the next appear.
        .onChange(of: app.libraryRevision) { _, _ in model.load(app.services) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.epub, .pdf, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { app.importFile(url) }
        }
        .alert(L10n.importFailedTitle, isPresented: showImportError) {
            Button(L10n.commonOK, role: .cancel) {}
        } message: {
            Text(app.importError ?? "")
        }
        .alert(L10n.libraryDeleteTitle, isPresented: showDeleteConfirm, presenting: pendingDelete) { item in
            Button(L10n.libraryDelete, role: .destructive) { model.delete(item.document, app.services) }
            Button(L10n.commonCancel, role: .cancel) {}
        } message: { item in
            Text(L10n.libraryDeleteBody(item.document.title))
        }
        .alert(L10n.importOCRConfirmTitle, isPresented: showOCRConfirm, presenting: app.pendingImportOCR) { p in
            Button(L10n.importOCRConfirmAction) { app.confirmImportOCR(p) }
            Button(L10n.commonCancel, role: .cancel) { app.cancelImportOCR(p) }
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
            if let p = app.importProgress { importBanner(p) }
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
        Binding(get: { app.importError != nil }, set: { if !$0 { app.importError = nil } })
    }

    private var showDeleteConfirm: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var showOCRConfirm: Binding<Bool> {
        Binding(get: { app.pendingImportOCR != nil }, set: { if !$0 { app.pendingImportOCR = nil } })
    }

    /// Shown when no books have been imported yet (the default on a fresh install,
    /// now that the sample shelf is dev-only). Keeps first run from looking broken.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.libraryEmptyTitle, systemImage: "books.vertical")
        } description: {
            Text(L10n.libraryEmptyBody)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Native large-title header with floating glass controls — a capsule cluster
    /// (membership + settings) and a circular add button, the Apple Music idiom.
    private var header: some View {
        HStack(alignment: .center) {
            Text(L10n.wordmark)
                .font(.largeTitle.bold())
            Spacer()
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    if !isSubscribed {
                        chromeIcon("star.circle", label: L10n.a11yMembership) { app.showPaywall = true }
                    }
                    chromeIcon("gearshape", label: L10n.a11ySettings) { showingSettings = true }
                }
                .glassEffect(.regular, in: Capsule())
                Button { importing = true } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityLabel(L10n.a11yAdd)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// One icon in the header's glass cluster (plain button; the shared capsule
    /// provides the glass).
    private func chromeIcon(_ systemImage: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(label)
    }

    private func row(_ item: LibraryModel.Item) -> some View {
        Button { app.open(item.document) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.document.title)
                        .font(.body).foregroundStyle(.primary).lineLimit(1)
                    if let author = item.document.author, !author.isEmpty {
                        Text(author)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if item.document.progress.fraction > 0 {
                        ProgressView(value: item.document.progress.fraction)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                if item.cached {
                    Image(systemName: "arrow.down.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.a11yAudioCached)
                }
                Text(item.statusLabel)
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
    }
}
