import SwiftUI

struct RootView: View {
    @State private var app = AppModel()

    var body: some View {
        ZStack {
            app.theme.bg.ignoresSafeArea()

            switch app.route {
            case .library:
                LibraryView()
                    .transition(.opacity)
            case .reader(let document):
                ReaderView(document: document)
                    .transition(.opacity)
            }
        }
        .environment(app)
        .environment(\.theme, app.theme)
        .tint(app.theme.accent)
        .onOpenURL { app.importFile($0) }
        .preferredColorScheme(app.themeName.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.25), value: app.route)
        .animation(.easeInOut(duration: 0.25), value: app.themeName)
        .sheet(isPresented: $app.showPaywall) {
            MembershipView()
                .environment(app)
                .environment(\.theme, app.theme)
                .tint(app.theme.accent)
        }
    }
}
