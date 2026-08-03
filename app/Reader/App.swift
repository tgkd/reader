import SwiftUI

@main
struct YomiApp: App {
    init() { AppServices.configureRevenueCat() }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}
