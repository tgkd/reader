import SwiftUI
import ReaderCore

/// Top-level UI state: the active theme and which screen is showing. Owns the
/// composed `AppServices`. The reader is a full-screen takeover (its own back
/// affordance), so navigation is a simple route enum rather than a NavigationStack
/// — matching the design's single-component screen switch.
@MainActor
@Observable
final class AppModel {
    var themeName: ThemeName = .paper
    var route: Route = .library

    let services = AppServices()

    enum Route: Equatable {
        case library
        case reader(Document)
    }

    var theme: Theme { themeName.theme }

    init() {
        #if DEBUG
        // Deterministic launch hooks for screenshots (pass via SIMCTL_CHILD_*):
        //   READER_THEME=paper|sepia|night, READER_OPEN=<library index>.
        let env = ProcessInfo.processInfo.environment
        if let t = env["READER_THEME"], let name = ThemeName(rawValue: t) { themeName = name }
        if let raw = env["READER_OPEN"], let i = Int(raw) {
            let docs = services.library.all()
            if docs.indices.contains(i) { route = .reader(docs[i]) }
        }
        // Import a file from a host path and open it (verifies the ingestion path).
        if let path = env["READER_IMPORT"],
           let doc = try? Importer.document(from: URL(fileURLWithPath: path)) {
            services.library.save(doc)
            route = .reader(doc)
        }
        #endif
    }

    func cycleTheme() { themeName = themeName.next }
    func open(_ document: Document) { route = .reader(document) }
    func backToLibrary() { route = .library }
}
