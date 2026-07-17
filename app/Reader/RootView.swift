import SwiftUI

/// Hosts the app, injects the resolved theme into the environment, and routes
/// between Library and Reader. The themed background fills the whole window so
/// theme switches feel like the design's instant palette swap.
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
        // Native controls (menus, sliders, alerts) tint with the theme's accent
        // instead of system blue, so glass chrome stays palette-coherent.
        .tint(app.theme.accent)
        // "Open in Yomi" from Files / Mail / Safari, and the share sheet.
        .onOpenURL { app.importFile($0) }
        .preferredColorScheme(app.themeName.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.25), value: app.route)
        .animation(.easeInOut(duration: 0.25), value: app.themeName)
        // Membership screen (features + subscribe/restore; opens the RevenueCat
        // paywall itself, and degrades safely when RevenueCat is unconfigured).
        // This sheet sits OUTSIDE the .environment wrappers above, so the sheet
        // content inherits neither — inject both explicitly.
        .sheet(isPresented: $app.showPaywall) {
            MembershipView()
                .environment(app)
                .environment(\.theme, app.theme)
                .tint(app.theme.accent)
        }
    }
}
