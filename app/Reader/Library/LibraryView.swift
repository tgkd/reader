import SwiftUI
import UniformTypeIdentifiers
import ReaderCore
import struct ReaderCore.Document

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var model = LibraryModel()
    @State private var importing = false
    @State private var showingPaste = false
    @State private var showingSettings = false
    @State private var pendingDelete: LibraryModel.Item?
    @State private var deleteFailed = false
    @State private var isSubscribed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.items.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.items) { item in
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
                .contentMargins(.bottom, app.importActivity == nil ? 0 : 94, for: .scrollContent)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.load(app.services)
        }
        .task {
            isSubscribed = await app.services.isSubscribed()
            for await active in app.services.entitlementUpdates() { isSubscribed = active }
        }
        .onChange(of: app.entitlementTick) { _, _ in
            Task { isSubscribed = await app.services.isSubscribed() }
        }
        .onChange(of: app.libraryRevision) { _, _ in model.load(app.services) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.epub, .pdf, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { app.importFile(url) }
            case .failure(let error):
                app.importErrorNeedsMembership = false
                app.importError = error.localizedDescription
            }
        }
        .alert(L10n.importFailedTitle, isPresented: showImportError) {
            if app.importErrorNeedsMembership {
                Button(L10n.readerSubscribeCTA) { app.showPaywall = true }
            }
            Button(L10n.commonOK, role: .cancel) {}
        } message: {
            Text(app.importError ?? "")
        }
        .alert(L10n.importPartialTitle, isPresented: showImportNotice) {
            if app.importNoticeNeedsMembership {
                Button(L10n.readerSubscribeCTA) { app.showPaywall = true }
            }
            Button(L10n.commonOK, role: .cancel) {}
        } message: {
            Text(app.importNotice ?? "")
        }
        .alert(L10n.libraryDeleteTitle, isPresented: showDeleteConfirm, presenting: pendingDelete) { item in
            Button(L10n.libraryDelete, role: .destructive) {
                Task { deleteFailed = !(await model.delete(item.document, app.services)) }
            }
            Button(L10n.commonCancel, role: .cancel) {}
        } message: { item in
            Text(L10n.libraryDeleteBody(item.document.title))
        }
        .alert(L10n.libraryDeleteFailedTitle, isPresented: $deleteFailed) {
            Button(L10n.commonOK, role: .cancel) {}
        } message: {
            Text(L10n.libraryDeleteFailedBody)
        }
        .alert(L10n.importOCRConfirmTitle, isPresented: showOCRConfirm, presenting: app.pendingImportOCR) { p in
            Button(L10n.importOCRConfirmAction) { app.confirmImportOCR(p) }
            Button(L10n.commonCancel, role: .cancel) { app.cancelImportOCR(p) }
        } message: { p in
            Text(L10n.importOCRConfirmBody(p.pageCount))
        }
        .sheet(isPresented: $showingPaste) {
            PasteTextView()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        .overlay(alignment: .bottom) {
            if let activity = app.importActivity {
                ImportProgressView(activity: activity, cancel: app.cancelImport)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.importActivity?.phase)
    }

    private var showImportError: Binding<Bool> {
        Binding(get: { app.importError != nil }, set: { if !$0 { app.importError = nil } })
    }

    private var showImportNotice: Binding<Bool> {
        Binding(get: { app.importNotice != nil }, set: { if !$0 { app.importNotice = nil } })
    }

    private var showDeleteConfirm: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var showOCRConfirm: Binding<Bool> {
        Binding(get: { app.pendingImportOCR != nil }, set: { if !$0 { app.pendingImportOCR = nil } })
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.libraryEmptyTitle, systemImage: "books.vertical")
        } description: {
            Text(L10n.libraryEmptyBody)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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
                Menu {
                    Button { importing = true } label: {
                        Label(L10n.libraryAddImportFile, systemImage: "folder")
                    }
                    .disabled(app.importActivity != nil)
                    Button { showingPaste = true } label: {
                        Label(L10n.libraryAddPasteText, systemImage: "document.on.clipboard")
                    }
                } label: {
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
                    if item.fraction > 0 {
                        ProgressView(value: item.fraction)
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
