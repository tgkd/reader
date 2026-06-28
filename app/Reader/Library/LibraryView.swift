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

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 22)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { row($0) }
                }
                .padding(.vertical, 6)
            }
        }
        .onAppear { model.load(app.services) }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.epub, .pdf, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .alert(L10n.importFailedTitle, isPresented: showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var showImportError: Binding<Bool> {
        Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })
    }

    /// Import the picked file (EPUB / PDF / .txt) into the library. The file is
    /// copied into the sandbox inside the security-scoped window (fast), then
    /// parsed off the main actor so a large EPUB/PDF doesn't freeze the UI; the new
    /// row appears when parsing finishes.
    private func handleImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
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
            defer { try? FileManager.default.removeItem(at: temp) }
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    try Importer.document(from: temp)
                }.value
                app.services.library.save(document)
                model.load(app.services)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 9, height: 9)
                Text(L10n.wordmark).font(Mincho.font(22)).foregroundStyle(theme.ink).tracking(3)
            }
            Spacer()
            HStack(spacing: 10) {
                IconButton(glyph: app.themeName.glyph, font: Mincho.font(15),
                           foreground: theme.muted, label: L10n.a11yTheme) { app.cycleTheme() }
                IconButton(glyph: "+", font: .system(size: 21, weight: .light),
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
                            .font(Mincho.font(19)).foregroundStyle(theme.ink).tracking(0.5)
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
