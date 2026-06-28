import SwiftUI
import RevenueCatUI

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
        .preferredColorScheme(app.themeName.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.25), value: app.route)
        .animation(.easeInOut(duration: 0.25), value: app.themeName)
        // Membership paywall (the RevenueCat-configured "pay" paywall). Shown via
        // app.showPaywall — the READER_PAYWALL=1 hook now, the entitlement gate next.
        .sheet(isPresented: $app.showPaywall) {
            PaywallView(displayCloseButton: true)
                .onPurchaseCompleted { _ in app.entitlementTick += 1; app.showPaywall = false }
                .onRestoreCompleted { _ in app.entitlementTick += 1; app.showPaywall = false }
        }
    }
}
