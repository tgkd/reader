import SwiftUI

/// Reading preferences, opened from the Library header gear. Currently the reading
/// font + text size; both apply live to the reader surface and persist. Hosted in a
/// native `.sheet` (grabber / swipe-to-dismiss / background come from the caller).
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    /// Gates the enhanced-OCR section — it's only useful (and only billable) for
    /// subscribers. Probed once on appear.
    @State private var isSubscriber = false

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

                if isSubscriber {
                    sectionHeader(L10n.settingsOCRSection)
                    optionRow(L10n.settingsOCRToggle,
                              font: .system(size: 16),
                              selected: app.enhancedOCR) { app.enhancedOCR.toggle() }
                    Text(L10n.settingsOCRNote)
                        .font(.system(size: 12)).foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24).padding(.top, 10)
                }
            }
            .padding(.bottom, 24)
        }
        .task { isSubscriber = await app.services.isSubscribed() }
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
