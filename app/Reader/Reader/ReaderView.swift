import SwiftUI
import ReaderCore
import struct ReaderCore.Document   // disambiguate from SwiftUI.Document

/// The Reader screen: a full-bleed reading surface with fading top/bottom chrome
/// and the tap-to-define sheet. Tapping a word opens the sheet; tapping empty
/// space toggles the chrome.
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
                    VStack(spacing: 0) { Spacer(); transport(model) }
                } else {
                    ProgressView().tint(theme.muted)
                }
            }
        }
        // Native bottom sheets — the system provides the grabber, dim, rounded
        // corners, swipe-to-dismiss, and modal VoiceOver focus. The background is
        // pinned to the theme so the themed text always contrasts it: a native
        // sheet otherwise follows the device appearance, not the app's forced
        // color scheme, which leaves a light theme's dark text on a dark sheet.
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
            // Rebuild for the current document. The `id:` makes this re-run if the
            // view is ever reused for a different document; current navigation
            // always creates a fresh ReaderView, so in practice it runs once.
            let m = ReaderModel(document: document, services: app.services)
            model = m
            await m.load()
        }
        .onDisappear { model?.stop() }
        .onChange(of: scenePhase) { _, phase in
            // Background audio keeps narrating with the screen locked; save the
            // playhead (or chapter) so a kill-while-backgrounded doesn't lose progress.
            if phase == .background { model?.saveProgressOnLeave() }
        }
        .onChange(of: app.entitlementTick) { _, _ in
            // A purchase/restore just unlocked `reader Pro` — retry the gated load.
            Task { await model?.load() }
        }
    }

    /// A Bool binding into the (optional) model, for native `.sheet` presentation.
    private func presented(_ keyPath: ReferenceWritableKeyPath<ReaderModel, Bool>) -> Binding<Bool> {
        Binding(get: { model?[keyPath: keyPath] ?? false },
                set: { model?[keyPath: keyPath] = $0 })
    }

    // MARK: - Reading surface

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
        // Full-bleed to the PHYSICAL screen edges (mid-scroll text runs under the
        // status bar and home indicator), so the chrome clearance — content insets
        // in yokogaki, the column band in tategaki — must include the safe area:
        // at rest the first/last line still clears the floating pills, but the
        // text scrolls under them, giving the glass something to blur.
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

    // MARK: - Top chrome

    /// Floating Liquid Glass chrome — no bar, no hairline: a glass circle for
    /// back, a glass title capsule (tap → chapters), and a glass capsule cluster
    /// for the quick toggles, all riding over the full-bleed text.
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
        // opacity(0) alone keeps the bar in the accessibility tree; hide it so
        // VoiceOver can't focus invisible controls once chrome is dismissed.
        .accessibilityHidden(!model.chromeVisible)
        .animation(.easeInOut(duration: 0.3), value: model.chromeVisible)
    }

    /// Book title + chapter subtitle in a floating glass capsule. On multi-chapter
    /// books the capsule IS the chapter selector — the up/down chevron (the native
    /// picker affordance) marks it as tappable; it opens the chapters sheet.
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

    /// One icon in the trailing glass cluster (plain button; the shared capsule
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

    /// Header subtitle: the chapter's real (TOC) title with a language-neutral
    /// position count, or the localized ordinal when the chapter is untitled.
    private func chapterSubtitle(_ model: ReaderModel) -> String {
        guard model.currentChapter?.title != nil else {
            return L10n.chapterOfCount(model.chapterIndex + 1, model.chapterCount)
        }
        return "\(model.chapterTitle) · \(model.chapterIndex + 1)/\(model.chapterCount)"
    }

    // MARK: - Transport

    /// The bottom chrome adapts to the audio state. Speech is the only gated
    /// feature, so a free user gets a single "Listen with Membership" pill instead
    /// of a dead scrubber; a subscriber gets a Play control that generates speech on
    /// demand, then the full transport once audio is ready.
    /// The player is ONE full-width floating glass pill (the Apple Music
    /// mini-player idiom), same height in every audio state — only its contents
    /// swap: paywall action, play, generation progress, or the full transport.
    @ViewBuilder private func transport(_ model: ReaderModel) -> some View {
        Group {
            switch model.audioState {
            case .locked:
                lockedPill
            case .idle, .notGenerated, .failed:
                preAudioPill(model)
            case .synthesizing:
                synthesizingPill(model)
            case .ready:
                playerPill(model)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
        .opacity(model.chromeVisible ? 1 : 0)
        .allowsHitTesting(model.chromeVisible)
        .accessibilityHidden(!model.chromeVisible)
        .animation(.easeInOut(duration: 0.3), value: model.chromeVisible)
    }

    /// Audio ready: play beside a native scrubber, remaining time, and a speed
    /// menu — a pure audio transport. Chapter switching lives in the header's
    /// title capsule (and the lock screen), never in the pill.
    private func playerPill(_ model: ReaderModel) -> some View {
        HStack(spacing: 2) {
            playPauseButton(model)
            Slider(value: seekBinding(model), in: 0...max(1, model.duration)) {
                Text(L10n.a11yPosition)
            }
            .tint(theme.accent)
            .padding(.horizontal, 6)
            Text("−" + model.timeLabel(max(0, model.duration - model.currentTime)))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            speedMenu(model)
        }
    }

    /// Free tier: audio is gated. One centered action that opens the paywall.
    private var lockedPill: some View {
        Button { app.showPaywall = true } label: {
            Text(L10n.readerSubscribeTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.accent)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(L10n.a11yMembership)
    }

    /// Subscribed but audio not generated yet (or a prior attempt failed): Play
    /// synthesizes on tap; a short status explains the failed / no-audio case.
    @ViewBuilder private func preAudioPill(_ model: ReaderModel) -> some View {
        HStack(spacing: 8) {
            if case .failed(let msg) = model.audioState {
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else if model.audioState == .notGenerated {
                Text(L10n.readerNotGeneratedTitle)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Button { model.startAudio() } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .accessibilityLabel(L10n.a11yPlay)
        }
        .frame(maxWidth: .infinity)
    }

    /// Determinate (estimated) progress while speech is generated — a real value
    /// so VoiceOver reads a percentage, unlike the old indeterminate spinner.
    /// No chapter arrows here: switching chapters would cancel the paid request.
    /// The X is the one deliberate way to abandon a running generation; without
    /// it a slow chapter reads as a hang.
    private func synthesizingPill(_ model: ReaderModel) -> some View {
        HStack(spacing: 8) {
            VStack(spacing: 4) {
                ProgressView(value: model.synthesisProgress)
                    .tint(theme.accent)
                    .animation(.linear(duration: 0.12), value: model.synthesisProgress)
                Text(L10n.readerGenerating)
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Button { model.cancelSynthesis() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.commonCancel)
        }
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    private func playPauseButton(_ model: ReaderModel) -> some View {
        Button { model.togglePlay() } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 22))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(model.isPlaying ? L10n.a11yPause : L10n.a11yPlay)
    }

    /// Two-way bridge for the native scrubber: reads the playhead, writes it
    /// through `seek`.
    private func seekBinding(_ model: ReaderModel) -> Binding<Double> {
        Binding(get: { model.currentTime }, set: { model.seek(to: $0) })
    }

    /// Native speed control: a menu with a checkmarked picker (0.75× / 1× / 1.25×).
    private func speedMenu(_ model: ReaderModel) -> some View {
        Menu {
            Picker(L10n.a11ySpeed,
                   selection: Binding(get: { model.speed }, set: { model.setSpeed($0) })) {
                ForEach([0.75, 1.0, 1.25], id: \.self) { v in
                    Text("\(speedText(v))×").tag(v)
                }
            }
        } label: {
            Text("\(speedText(model.speed))×")
                .font(.footnote.weight(.medium)).monospacedDigit()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.a11ySpeed)
    }

    private func speedText(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)
    }

    // MARK: - Chapters (multi-chapter imports)

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
    }
}
