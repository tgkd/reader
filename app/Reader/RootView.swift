import SwiftUI
import RevenueCat
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
        // "Open in Yomi" from Files / Mail / Safari, and the share sheet.
        .onOpenURL { app.importFile($0) }
        .preferredColorScheme(app.themeName.isDark ? .dark : .light)
        .animation(.easeInOut(duration: 0.25), value: app.route)
        .animation(.easeInOut(duration: 0.25), value: app.themeName)
        // Membership paywall (the RevenueCat-configured "pay" paywall).
        .sheet(isPresented: $app.showPaywall) {
            // Guard: `PaywallView` touches `Purchases.shared`, which fatalErrors if
            // RevenueCat was never configured — and a device build with a test_/empty
            // SDK key skips configure (see AppServices.configureRevenueCat). A
            // misconfigured build shouldn't ship, but it must never crash here.
            if Purchases.isConfigured {
                PaywallView(displayCloseButton: true)
                    .onPurchaseCompleted { _ in app.entitlementTick += 1; app.showPaywall = false }
                    .onRestoreCompleted { _ in app.entitlementTick += 1; app.showPaywall = false }
            } else {
                membershipUnavailable
            }
        }
    }

    /// Shown instead of `PaywallView` when RevenueCat isn't configured — a safe,
    /// dismissable fallback so the membership button can't crash a misconfigured build.
    private var membershipUnavailable: some View {
        VStack(spacing: 16) {
            Text(L10n.membershipUnavailable)
                .font(.system(size: 15)).foregroundStyle(app.theme.ink)
                .multilineTextAlignment(.center)
            Button(L10n.commonOK) { app.showPaywall = false }
                .foregroundStyle(app.theme.accent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(app.theme.bg.ignoresSafeArea())
    }
}
