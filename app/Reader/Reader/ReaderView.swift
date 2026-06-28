import SwiftUI
import ReaderCore

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
        ZStack {
            theme.bg.ignoresSafeArea()
            if let model {
                surface(model)
                VStack(spacing: 0) { topBar(model); Spacer() }
                VStack(spacing: 0) { Spacer(); transport(model) }
                sheetLayer(model)
                chaptersLayer(model)
            } else {
                ProgressView().tint(theme.muted)
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
            // playhead so a kill-while-backgrounded doesn't lose progress.
            if phase == .background { model?.persistProgress() }
        }
    }

    // MARK: - Reading surface

    @ViewBuilder private func surface(_ model: ReaderModel) -> some View {
        Group {
            switch model.loadState {
            case .loading:
                ProgressView().tint(theme.muted)
            case .ready:
                RubyTextView(
                    spans: model.spans,
                    structureVersion: model.structureVersion,
                    activeIndex: model.activeIndex,
                    vertical: model.orientation == .tate,
                    theme: theme,
                    onTapToken: { model.tapToken($0) },
                    onTapBackground: { model.toggleChrome() }
                )
            case .notGenerated:
                placeholder(L10n.readerNotGeneratedTitle, L10n.readerNotGeneratedBody)
            case .failed(let msg):
                placeholder(L10n.readerFailedTitle, msg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
        .padding(.top, 94)
        // Clears the transport chrome (~136pt with the taller scrubber row) so the
        // last text line can't tuck under the transport's opaque background.
        .padding(.bottom, 140)
    }

    private func placeholder(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(Mincho.font(20)).foregroundStyle(theme.ink)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { model?.toggleChrome() }
    }

    // MARK: - Top chrome

    private func topBar(_ model: ReaderModel) -> some View {
        HStack(spacing: 8) {
            Button { app.backToLibrary() } label: {
                Text("‹").font(.system(size: 27, weight: .light)).foregroundStyle(theme.ink)
                    .frame(width: 40, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.a11yBack)

            Text(document.title)
                .font(Mincho.font(15)).foregroundStyle(theme.ink).tracking(1)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity)

            HStack(spacing: 9) {
                if model.hasChapters {
                    IconButton(glyph: "目", font: Mincho.font(15),
                               foreground: theme.muted, outline: .rounded, label: L10n.chapters) {
                        model.chaptersVisible = true
                    }
                }
                IconButton(glyph: model.orientation == .tate ? "縦" : "横",
                           font: Mincho.font(15), foreground: theme.ink, outline: .rounded,
                           label: L10n.a11yOrientation) {
                    model.toggleOrientation()
                }
                IconButton(glyph: app.themeName.glyph,
                           font: Mincho.font(15), foreground: theme.muted, outline: .rounded,
                           label: L10n.a11yTheme) {
                    app.cycleTheme()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(theme.bg)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.hair).frame(height: 1) }
        .opacity(model.chromeVisible ? 1 : 0)
        .allowsHitTesting(model.chromeVisible)
        // opacity(0) alone keeps the bar in the accessibility tree; hide it so
        // VoiceOver can't focus invisible controls once chrome is dismissed.
        .accessibilityHidden(!model.chromeVisible)
        .animation(.easeInOut(duration: 0.3), value: model.chromeVisible)
    }

    // MARK: - Transport

    private func transport(_ model: ReaderModel) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 11) {
                Text(model.timeLabel(model.currentTime))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted)
                    .frame(width: 30, alignment: .leading)
                scrubber(model)
                    .frame(height: 28)   // taller touch target; capsule stays 3pt, centered
                Text(model.timeLabel(model.duration))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.muted)
                    .frame(width: 30, alignment: .trailing)
            }
            HStack {
                Button { model.togglePlay() } label: { playPause(model) }
                    .buttonStyle(.plain)
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(theme.hair, lineWidth: 1))
                    .accessibilityLabel(model.isPlaying ? L10n.a11yPause : L10n.a11yPlay)
                Spacer()
                speedPicker(model)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 30)
        .background(theme.bg)
        .overlay(alignment: .top) { Rectangle().fill(theme.hair).frame(height: 1) }
        .opacity(model.chromeVisible ? 1 : 0)
        .allowsHitTesting(model.chromeVisible)
        .accessibilityHidden(!model.chromeVisible)
        .animation(.easeInOut(duration: 0.3), value: model.chromeVisible)
    }

    private func scrubber(_ model: ReaderModel) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = w * model.progressFraction
            ZStack(alignment: .leading) {
                Capsule().fill(theme.soft).frame(height: 3)
                Capsule().fill(theme.accent).frame(width: max(0, x), height: 3)
                Circle().fill(theme.accent).frame(width: 11, height: 11)
                    .overlay(Circle().stroke(theme.bg, lineWidth: 3))
                    .position(x: x, y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard w > 0, model.duration > 0 else { return }
                        let fraction = min(max(0, value.location.x / w), 1)
                        model.seek(to: fraction * model.duration)
                    }
            )
        }
        // Keep the bespoke visual but hand VoiceOver a real, adjustable slider —
        // only once there's audio, so we never present a dead adjustable control.
        .accessibilityRepresentation {
            Slider(value: seekBinding(model), in: 0...max(1, model.duration)) {
                Text(L10n.a11yPosition)
            }
        }
        .accessibilityHidden(model.duration <= 0)
    }

    /// Two-way bridge for the scrubber's VoiceOver slider: reads the playhead,
    /// writes it through `seek`.
    private func seekBinding(_ model: ReaderModel) -> Binding<Double> {
        Binding(get: { model.currentTime }, set: { model.seek(to: $0) })
    }

    @ViewBuilder private func playPause(_ model: ReaderModel) -> some View {
        if model.isPlaying {
            HStack(spacing: 4) {
                Capsule().frame(width: 4, height: 16)
                Capsule().frame(width: 4, height: 16)
            }
            .foregroundStyle(theme.ink)
        } else {
            PlayTriangle().fill(theme.ink).frame(width: 14, height: 18).offset(x: 2)
        }
    }

    private func speedPicker(_ model: ReaderModel) -> some View {
        HStack(spacing: 0) {
            ForEach([0.75, 1.0, 1.25], id: \.self) { v in
                let active = model.speed == v
                Button { model.setSpeed(v) } label: {
                    Text(v == 1.0 ? "1.0×" : "\(speedText(v))×")
                        .font(.system(size: 12)).tracking(0.3)
                        .foregroundStyle(active ? theme.onAccent : theme.muted)
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(active ? theme.accent : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .clipShape(Capsule())
        .overlay(Capsule().stroke(theme.hair, lineWidth: 1))
    }

    private func speedText(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)
    }

    // MARK: - Dictionary sheet

    @ViewBuilder private func sheetLayer(_ model: ReaderModel) -> some View {
        ZStack(alignment: .bottom) {
            Color.black
                .opacity(model.sheetVisible ? 0.34 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(model.sheetVisible)
                .onTapGesture { model.closeSheet() }

            if model.sheetVisible {
                DefinitionSheet(model: model)
                    .accessibilityAddTraits(.isModal)   // scope VoiceOver to the sheet
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: model.sheetVisible)
    }

    // MARK: - Chapters (multi-chapter imports)

    @ViewBuilder private func chaptersLayer(_ model: ReaderModel) -> some View {
        ZStack(alignment: .bottom) {
            Color.black
                .opacity(model.chaptersVisible ? 0.34 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(model.chaptersVisible)
                .onTapGesture { model.chaptersVisible = false }

            if model.chaptersVisible {
                chaptersSheet(model)
                    .accessibilityAddTraits(.isModal)   // scope VoiceOver to the sheet
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.88), value: model.chaptersVisible)
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
                                Text(chapter.title ?? "第\(i + 1)章")
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
            .frame(maxHeight: 360)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(theme.bg)
        .clipShape(.rect(topLeadingRadius: 18, topTrailingRadius: 18, style: .circular))
        .ignoresSafeArea(edges: .bottom)
    }
}
