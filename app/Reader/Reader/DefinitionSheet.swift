import SwiftUI
import ReaderCore

/// The tap-to-define bottom sheet: headword + reading, play/save controls,
/// part-of-speech, numbered senses, and an optional example. Matches the design;
/// data comes from the `DictionaryService` (mock now, jisho-seed.db later).
struct DefinitionSheet: View {
    let model: ReaderModel
    @Environment(\.theme) private var theme

    private var entry: DictionaryEntry? { model.entry }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(theme.hair).frame(width: 40, height: 5)
                .frame(maxWidth: .infinity).padding(.bottom, 18)

            header

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
                    Text(ex.japanese).font(Mincho.font(17)).foregroundStyle(theme.ink).tracking(0.5)
                    Text(ex.english).font(.system(size: 12.5)).foregroundStyle(theme.muted)
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.soft)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 18)
            }

            Button { model.toggleSaved() } label: {
                Text(model.saved ? L10n.dictSaved : L10n.dictSave)
                    .font(.system(size: 14)).tracking(1).foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity).padding(13)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.hair, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .clipShape(RoundedCorner(radius: 22, corners: [.topLeft, .topRight]))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.reading ?? "")
                    .font(.system(size: 13)).foregroundStyle(theme.muted).tracking(1)
                Text(entry?.word ?? "")
                    .font(Mincho.font(36)).foregroundStyle(theme.ink).tracking(1)
            }
            Spacer()
            HStack(spacing: 9) {
                Button { } label: {
                    PlayTriangle().fill(theme.accent).frame(width: 10, height: 13).offset(x: 1)
                        .frame(width: 38, height: 38).overlay(Circle().stroke(theme.hair, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button { model.toggleSaved() } label: {
                    Text(model.saved ? "♥" : "♡")
                        .font(.system(size: 17)).foregroundStyle(theme.accent)
                        .frame(width: 38, height: 38).overlay(Circle().stroke(theme.hair, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
    }

    private var posLabel: String {
        entry?.senses.first?.partsOfSpeech.joined(separator: " · ") ?? "—"
    }

    private var meanings: [String] {
        (entry?.senses ?? []).map { $0.glosses.joined(separator: "; ") }
    }
}
