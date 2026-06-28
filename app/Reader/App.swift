import SwiftUI

/// Yomi — Japanese reader with word-synced audio. App entry point.
@main
struct YomiApp: App {
    /// Configure RevenueCat before the first `AppServices` (created by `RootView`'s
    /// `@State`) reads `Purchases.shared.appUserID` for the Worker's X-User-ID.
    init() { AppServices.configureRevenueCat() }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}
