import SwiftUI
import ReaderCore
import struct ReaderCore.Document

struct ReaderView: View {
    let document: Document

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: ReaderModel?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.bg.ignoresSafeArea()
                if let model {
                    surface(model, safeArea: geo.safeAreaInsets)
                    VStack(spacing: 0) { topBar(model); Spacer() }
                    VStack(spacing: 0) { Spacer(); transport(model, width: geo.size.width) }
                } else {
                    ProgressView().tint(theme.muted)
                }
            }
        }
        .sheet(isPresented: presented(\.sheetVisible)) {
            if let model {
                DefinitionSheet(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(theme.surface)
            }
        }
        .sheet(isPresented: presented(\.chaptersVisible)) {
            if let model {
                chaptersSheet(model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(theme.bg)
            }
        }
        .task(id: document.id) {
            let m = ReaderModel(document: document, services: app.services)
            model = m
            await m.load()
        }
        .onDisappear { model?.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model?.saveProgressOnLeave() }
        }
        .onChange(of: app.entitlementTick) { _, _ in
            Task { await model?.load() }
        }
    }

    private func presented(_ keyPath: ReferenceWritableKeyPath<ReaderModel, Bool>) -> Binding<Bool> {
        Binding(get: { model?[keyPath: keyPath] ?? false },
                set: { model?[keyPath: keyPath] = $0 })
    }

    @ViewBuilder private func surface(_ model: ReaderModel, safeArea: EdgeInsets) -> some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView().tint(theme.muted)
            case .ready:
                RubyTextView(
                    spans: model.spans,
                    structureVersion: model.structureVersion,
                    activeIndex: model.activeIndex,
                    vertical: app.readingOrientation.isVertical,
                    theme: theme,
                    fontName: app.readingFont.psName,
                    fontScale: app.readingSize.scale,
                    showFurigana: app.showFurigana,
                    topInset: 64 + safeArea.top,
                    bottomInset: 88 + safeArea.bottom,
                    onTapToken: { model.tapToken($0) },
                    onTapBackground: { model.toggleChrome() },
                    onNextChapter: model.canGoToNextChapter
                        ? { Task { await model.openChapter(model.chapterIndex + 1) } }
                        : nil
                )
            case .failed(let msg):
                placeholder(L10n.readerFailedTitle, msg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(Mincho.font(20)).foregroundStyle(theme.ink)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model?.toggleChrome() }
    }

    private func topBar(_ model: ReaderModel) -> some View {
        HStack(spacing: 10) {
            Button { app.backToLibrary() } label: {
                Image(systemName: "chevron.backward")
                    .fontWeight(.semibold)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .glassEffect(.regular.interactive(), in: Circle())
            .accessibilityLabel(L10n.a11yBack)

            Spacer(minLength: 6)
            titleCluster(model)
            Spacer(minLength: 6)

            HStack(spacing: 0) {
                chromeIcon(app.readingOrientation.isVertical ? "arrow.up.and.down" : "arrow.left.and.right",
                           label: L10n.a11yOrientation) {
                    app.readingOrientation = app.readingOrientation == .tate ? .yoko : .tate
                }
                chromeIcon(app.themeName.symbol, label: L10n.a11yTheme) {
                    app.cycleTheme()
                }
            }
            .glassEffect(.regular, in: Capsule())
        }
        .padding(.horizontal, 12)
        .opacity(model.chromeVisible ? 1 : 0)
        .allowsHitTesting(model.chromeVisible)
        .accessibilityHidden(!model.chromeVisible)
        .animation(.easeInOut(duration: 0.3), value: model.chromeVisible)
    }

    @ViewBuilder private func titleCluster(_ model: ReaderModel) -> some View {
        let title = VStack(spacing: 1) {
            Text(document.title)
                .font(.footnote.weight(.semibold)).lineLimit(1)
            if model.hasChapters {
                Text(chapterSubtitle(model))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }

        if model.hasChapters {
            Button { model.chaptersVisible = true } label: {
                HStack(spacing: 6) {
                    title
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityHint(L10n.chapters)
        } else {
            title
                .padding(.horizontal, 16)
                .frame(height: 44)
                .glassEffect(.regular, in: Capsule())
        }
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

    private func chapterSubtitle(_ model: ReaderModel) -> String {
        guard model.currentChapter?.title != nil else {
            return L10n.chapterOfCount(model.chapterIndex + 1, model.chapterCount)
        }
        return "\(model.chapterTitle) · \(model.chapterIndex + 1)/\(model.chapterCount)"
    }

    @ViewBuilder private func transport(_ model: ReaderModel, width: CGFloat) -> some View {
        PlayerView(model: model, expandedWidth: width - 32)
            .padding(.trailing, 16)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .opacity(model.chromeVisible ? 1 : 0)
            .allowsHitTesting(model.chromeVisible)
            .accessibilityHidden(!model.chromeVisible)
            .animation(.easeInOut(duration: 0.3), value: model.chromeVisible)
    }

    private func chaptersSheet(_ model: ReaderModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.chapters)
                .font(Mincho.font(17)).foregroundStyle(theme.ink).tracking(1)
                .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 10)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.document.chapters.enumerated()), id: \.element.id) { i, chapter in
                        Button { Task { await model.openChapter(i) } } label: {
                            HStack {
                                Text(chapter.title ?? L10n.chapterNumber(i + 1))
                                    .font(Mincho.font(15))
                                    .foregroundStyle(i == model.chapterIndex ? theme.accent : theme.ink)
                                    .lineLimit(1).truncationMode(.tail)
                                Spacer(minLength: 12)
                                if model.cachedChapters.contains(i) {
                                    Image(systemName: "arrow.down.circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(theme.muted)
                                        .accessibilityLabel(L10n.a11yAudioCached)
                                }
                                if i == model.chapterIndex {
                                    PlayTriangle().fill(theme.accent).frame(width: 9, height: 11)
                                }
                            }
                            .padding(.horizontal, 22).padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(i == model.chapterIndex ? .isSelected : [])
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 22)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { model.refreshCachedChapters() }
    }
}
