import SwiftUI

/// "Paste text" import sheet: a title field, a big text area, one Add action.
/// Pasted text takes the exact .txt pipeline downstream (one chapter, split to
/// renderable size) — the zero-friction way in for the copy-paste-shaped texts
/// learners actually read (web novels, articles, lyrics, messages). The
/// clipboard is never read programmatically — the user pastes into the editor
/// themselves, so no iOS paste-notification banner.
struct PasteTextView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var text = ""

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.libraryAddPasteText)
                .font(Mincho.font(22)).foregroundStyle(theme.ink).tracking(1)
                .padding(.top, 28)

            TextField(L10n.pasteTitleField, text: $title)
                .font(.system(size: 16))
                .foregroundStyle(theme.ink)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))

            TextEditor(text: $text)
                .font(.system(size: 16))
                .foregroundStyle(theme.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L10n.pastePlaceholder)
                            .font(.system(size: 16)).foregroundStyle(theme.muted)
                            .padding(.horizontal, 15).padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            Button {
                app.importPastedText(title: title, text: text)
                dismiss()
            } label: {
                Text(L10n.pasteAdd)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
            .opacity(isEmpty ? 0.4 : 1)
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 20)
        .presentationBackground(theme.bg)
        .presentationDragIndicator(.visible)
    }
}
