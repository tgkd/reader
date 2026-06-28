import SwiftUI
import ReaderCore

/// Sync spike overlay: highlighted text + a debug panel showing the playhead,
/// the active token, and the highlight-vs-audio offset. Purpose is to eyeball
/// whether the highlight tracks the spoken word (the >95% / <150 ms threshold).
struct ContentView: View {
    @State private var model = SyncModel()

    var body: some View {
        VStack(spacing: 16) {
            if model.fixtureNames.count > 1 {
                Picker("Fixture", selection: Binding(
                    get: { model.selected },
                    set: { model.selected = $0; model.load($0) }
                )) {
                    ForEach(model.fixtureNames, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            ScrollView {
                Text(highlighted)
                    .lineSpacing(10)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            debugPanel

            HStack(spacing: 12) {
                Button(model.isPlaying ? "Pause" : "Play") { model.toggle() }
                    .buttonStyle(.borderedProminent)
                Button("Restart") { model.restart() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .onAppear { model.bootstrap() }
    }

    /// Built from token surfaces (which reconstruct the text 1:1), tinting the
    /// active token with a real highlight box. No string-index math needed.
    private var highlighted: AttributedString {
        var result = AttributedString()
        for (i, span) in model.spans.enumerated() {
            var piece = AttributedString(span.surface)
            piece.font = .system(size: 30)
            if i == model.activeIndex {
                piece.backgroundColor = .yellow
                piece.foregroundColor = .black
            } else {
                piece.foregroundColor = .primary
            }
            result += piece
        }
        return result
    }

    private var debugPanel: some View {
        let active = model.activeIndex.flatMap { model.spans.indices.contains($0) ? model.spans[$0] : nil }
        let offsetMs = active.map { (model.currentTime - $0.start) * 1000 } ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(String(format: "t = %.2f / %.2f s", model.currentTime, model.duration))
            if let a = active {
                Text("active: \(a.surface)\(a.reading.map { " (\($0))" } ?? "")  [\(fmt(a.start))–\(fmt(a.end))]")
                Text(String(format: "into-token %+.0f ms   ·   token %d/%d",
                            offsetMs, (model.activeIndex ?? 0) + 1, model.spans.count))
            } else {
                Text("active: —")
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func fmt(_ t: Double) -> String { String(format: "%.2f", t) }
}
