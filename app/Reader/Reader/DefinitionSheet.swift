import SwiftUI
import ReaderCore

struct DefinitionSheet: View {
    let model: ReaderModel
    @Environment(\.theme) private var theme
    @Environment(AppModel.self) private var app

    private var entry: DictionaryEntry? { model.entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                if model.lookupChoices.count > 1 { choiceRow }

                Text(posLabel)
                    .font(.system(size: 12.5).italic()).foregroundStyle(theme.muted)
                    .padding(.top, 10)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(meanings.enumerated()), id: \.offset) { i, text in
                        HStack(alignment: .firstTextBaseline, spacing: 11) {
                            Text("\(i + 1).")
                                .font(.system(size: 12)).monospacedDigit().foregroundStyle(theme.muted)
                                .frame(width: 13, alignment: .leading)
                            Text(text).font(.system(size: 16)).foregroundStyle(theme.ink).lineSpacing(4)
                        }
                    }
                }
                .padding(.top, 14)

                if let ex = entry?.example {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(ex.japanese).font(app.readingFont.font(17)).foregroundStyle(theme.ink).tracking(0.5)
                        Text(ex.english).font(.system(size: 12.5)).foregroundStyle(theme.muted)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.soft)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.top, 18)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 14) {
                Text(entry?.word ?? "")
                    .font(app.readingFont.font(36)).foregroundStyle(theme.ink).tracking(1)
                Spacer()
                Button { model.pronounceEntry() } label: {
                    PlayTriangle().fill(theme.accent).frame(width: 10, height: 13).offset(x: 1)
                        .frame(width: 38, height: 38).overlay(Circle().stroke(theme.hair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.a11yPlayWord)
                .padding(.top, 6)
            }
            Text(entry?.reading ?? "")
                .font(app.readingFont.font(14)).foregroundStyle(theme.muted).tracking(1)
        }
    }

    private var choiceRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.lookupChoices, id: \.surface) { choice in
                    let isSelected = choice.surface == model.selectedChoice
                    Button { model.selectChoice(choice.surface) } label: {
                        Text(choice.surface)
                            .font(app.readingFont.font(15))
                            .foregroundStyle(isSelected ? theme.onAccent : theme.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? theme.accent : theme.soft)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 14)
    }

    private var posLabel: String {
        entry?.senses.first?.partsOfSpeech.joined(separator: " · ") ?? "—"
    }

    private var meanings: [String] {
        (entry?.senses ?? []).map { $0.glosses.joined(separator: "; ") }
    }
}
