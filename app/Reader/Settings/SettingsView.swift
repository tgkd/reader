import SwiftUI
import ReaderCore
import RevenueCat

/// Reading preferences, opened from the Library header gear. Currently the reading
/// font + text size; both apply live to the reader surface and persist. Hosted in a
/// native `.sheet` (grabber / swipe-to-dismiss / background come from the caller).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// Bytes of cached narration on disk; refreshed on appear and after clearing.
    @State private var cacheBytes = 0
    @State private var showClearConfirm = false
    /// Gates the narration-voice section — a paid knob, hidden on the free tier.
    @State private var isSubscribed = false
    @State private var demo = VoiceDemoPlayer()
    @State private var showingAbout = false
    @State private var showingPaywall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L10n.settings)
                    .font(Mincho.font(20)).foregroundStyle(theme.ink).tracking(1)
                    .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 6)

                sectionHeader(L10n.settingsFont)
                ForEach(ReadingFont.allCases) { font in
                    // Preview each option rendered in its own face.
                    optionRow(font.displayName,
                              font: .custom(font.psName, size: 19),
                              selected: app.readingFont == font) { app.readingFont = font }
                }

                sectionHeader(L10n.settingsSize)
                ForEach(ReadingSize.allCases) { size in
                    // Preview the size in the currently-selected face.
                    optionRow(size.displayName,
                              font: .custom(app.readingFont.psName, size: 15 * size.scale),
                              selected: app.readingSize == size) { app.readingSize = size }
                }

                sectionHeader(L10n.settingsDirection)
                ForEach(Orientation.allCases) { ori in
                    optionRow(ori.displayName,
                              font: .system(size: 16),
                              selected: app.readingOrientation == ori) { app.readingOrientation = ori }
                }

                sectionHeader(L10n.settingsFurigana)
                optionRow(L10n.furiganaShow, font: .system(size: 16),
                          selected: app.showFurigana) { app.showFurigana = true }
                optionRow(L10n.furiganaHide, font: .system(size: 16),
                          selected: !app.showFurigana) { app.showFurigana = false }

                sectionHeader(L10n.settingsTheme)
                ForEach(ThemeName.allCases, id: \.self) { name in
                    optionRow(name.displayName,
                              font: .system(size: 16),
                              selected: app.themeName == name) { app.themeName = name }
                }

                // Narration voice — synthesis is the paid feature, so the picker
                // only exists for subscribers (mirrors the Worker's server gate).
                if isSubscribed {
                    sectionHeader(L10n.settingsVoice)
                    ForEach(Voice.catalog) { voice in
                        voiceRow(voice)
                    }
                    Text(L10n.settingsVoiceNote)
                        .font(.system(size: 11.5)).foregroundStyle(theme.muted)
                        .padding(.horizontal, 24).padding(.top, 8)
                }

                sectionHeader(L10n.settingsMembership)
                membershipBlock

                sectionHeader(L10n.settingsStorage)
                storageRow

                aboutRow
            }
            .padding(.bottom, 24)
        }
        .onAppear { cacheBytes = app.services.audioStore.totalBytes() }
        .task { isSubscribed = await app.services.isSubscribed() }
        .onDisappear { demo.stop() }
        .sheet(isPresented: $showingAbout) {
            AboutView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(theme.bg)
        }
        // Membership screen (features + subscribe/restore) — same sheet RootView
        // presents; it opens the RevenueCat paywall itself and degrades safely
        // when RevenueCat is unconfigured.
        .sheet(isPresented: $showingPaywall) {
            MembershipView()
        }
        // A purchase/restore just completed — flip the membership block (and the
        // voice section's gate) live.
        .onChange(of: app.entitlementTick) { _, _ in
            Task { isSubscribed = await app.services.isSubscribed() }
        }
        .alert(L10n.storageClearTitle, isPresented: $showClearConfirm) {
            Button(L10n.storageClear, role: .destructive) {
                app.services.audioStore.clear()
                cacheBytes = app.services.audioStore.totalBytes()
            }
            Button(L10n.commonCancel, role: .cancel) {}
        } message: {
            Text(L10n.storageClearBody)
        }
    }

    /// Destructive action row: the cache size on the right, tapping it confirms a
    /// full clear. Disabled (and muted) when nothing is cached.
    private var storageRow: some View {
        let empty = cacheBytes <= 0
        return Button { showClearConfirm = true } label: {
            HStack {
                Text(L10n.storageClear)
                    .font(.system(size: 16)).foregroundStyle(empty ? theme.muted : theme.accent)
                Spacer(minLength: 12)
                Text(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file))
                    .font(.system(size: 13)).monospacedDigit().foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(empty)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 24)
        }
    }

    /// An `optionRow`-style voice pick with a trailing sample button: spinner while
    /// the sample synthesizes (first listen only — cached after), stop while playing.
    private func voiceRow(_ voice: Voice) -> some View {
        let selected = app.narrationVoice == voice
        return HStack(spacing: 0) {
            Button { app.narrationVoice = voice } label: {
                HStack {
                    Text(voice.name)
                        .font(.system(size: 16)).foregroundStyle(selected ? theme.accent : theme.ink)
                    Spacer(minLength: 12)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                    }
                }
                .padding(.leading, 24).padding(.vertical, 15)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button { demo.toggle(voice, services: app.services) } label: {
                Group {
                    if demo.synthesizingID == voice.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: demo.playingID == voice.id ? "stop.fill" : "play.circle")
                            .font(.system(size: 19)).foregroundStyle(theme.accent)
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .accessibilityLabel(L10n.a11yVoiceDemo)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 24)
        }
    }

    /// Membership block: active status + subscription management for subscribers,
    /// the paywall entry for everyone else (the Library upsell star hides once
    /// subscribed, so this is the durable home for membership).
    @ViewBuilder private var membershipBlock: some View {
        if isSubscribed {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15)).foregroundStyle(theme.accent)
                Text(L10n.membershipActive).font(.system(size: 16)).foregroundStyle(theme.ink)
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 24)
            }
            // RevenueCat resolves the subscription's real management surface — the
            // native App Store sheet when possible, the web subscriptions page
            // otherwise. StoreKit's `.manageSubscriptionsSheet` silently presented
            // NOTHING when the signed-in Apple ID had no resolvable subscription
            // (the TestFlight case). This row only renders when subscribed, which
            // requires a configured RevenueCat, so `Purchases.shared` is safe here.
            // Failures are logged by the SDK; Settings has no error surface.
            actionRow(L10n.membershipManage) {
                Task { try? await Purchases.shared.showManageSubscriptions() }
            }
        } else {
            actionRow(L10n.readerSubscribeCTA) { showingPaywall = true }
        }
    }

    private func actionRow(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(.system(size: 16)).foregroundStyle(theme.accent)
                Spacer(minLength: 12)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 24)
        }
    }

    /// Version, product links, and data-source attributions live one level down.
    private var aboutRow: some View {
        Button { showingAbout = true } label: {
            HStack {
                Text(L10n.settingsAbout).font(.system(size: 16)).foregroundStyle(theme.ink)
                Spacer(minLength: 12)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 24)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 24)
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium)).tracking(1.5).textCase(.uppercase)
            .foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 6)
    }

    private func optionRow(_ label: String, font: Font, selected: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(font).foregroundStyle(selected ? theme.accent : theme.ink)
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 24)
        }
    }
}
