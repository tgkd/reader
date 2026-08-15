import SwiftUI

struct StarterBooksView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme

    @State private var adding: StarterLibrary.Book.ID?

    private var present: Set<StarterLibrary.Book.ID> {
        _ = app.libraryRevision
        return Set(StarterLibrary.books.filter { app.libraryContains($0) }.map(\.id))
    }

    var body: some View {
        let inLibrary = present
        VStack(spacing: 0) {
            Text(L10n.libraryAddSampleBooks)
                .font(Mincho.font(22)).foregroundStyle(theme.ink).tracking(1)
                .padding(.top, 28)

            Text(L10n.sampleBooksNote)
                .font(.system(size: 13)).foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(StarterLibrary.books) { book in
                        row(book, added: inLibrary.contains(book.id))
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
        .presentationBackground(theme.bg)
        .presentationDragIndicator(.visible)
    }

    private func row(_ book: StarterLibrary.Book, added: Bool) -> some View {
        Button {
            Task {
                adding = book.id
                await app.importStarterBook(book)
                adding = nil
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(Mincho.font(17)).foregroundStyle(theme.ink)
                    Text(book.author)
                        .font(.system(size: 13)).foregroundStyle(theme.muted)
                }
                Spacer(minLength: 8)
                if adding == book.id {
                    ProgressView()
                } else {
                    Image(systemName: added ? "checkmark" : "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(added ? theme.muted : theme.accent)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(added || adding != nil)
        .opacity(added ? 0.55 : 1)
        .accessibilityLabel("\(book.title)、\(book.author)")
        .accessibilityValue(added ? L10n.sampleBooksAdded : "")
    }
}
