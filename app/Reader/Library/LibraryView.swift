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
