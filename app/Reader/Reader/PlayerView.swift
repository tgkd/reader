import SwiftUI

struct PlayerView: View {
    let model: ReaderModel
    let expandedWidth: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var isExpanded = false
    @Namespace private var glassNS

    private enum Row: Equatable {
        case ready, synthesizing, locked, preAudio

        init(_ state: ReaderModel.AudioState) {
            switch state {
            case .ready: self = .ready
            case .synthesizing: self = .synthesizing
            case .locked: self = .locked
            case .idle, .notGenerated, .interrupted, .failed: self = .preAudio
            }
        }
    }

    private var row: Row { Row(model.audioState) }

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .bottomTrailing) {
                if isExpanded {
                    expandedCapsule
                } else {
                    collapsedCircle
                }
            }
        }
        .animation(.smooth(duration: 0.38), value: isExpanded)
    }

    private var collapsedCircle: some View {
        Button { isExpanded = true } label: {
            ZStack {
                if row == .ready || row == .synthesizing {
                    progressRing
                }
                collapsedCenter
            }
            .frame(width: 58, height: 58)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .glassEffectID("player", in: glassNS)
        .accessibilityLabel(L10n.a11yPlayerExpand)
        .accessibilityValue(collapsedA11yValue)
    }

    private var progressRing: some View {
        ZStack {
            Circle().inset(by: 4.5)
                .stroke(theme.soft, lineWidth: 3)
            Circle().inset(by: 4.5)
                .trim(from: 0, to: row == .synthesizing ? model.synthesisProgress : model.progressFraction)
                .stroke(theme.accent, style: StrokeStyle(lineWidth: 3))
                .rotationEffect(.degrees(-90))
                .animation(row == .synthesizing ? .linear(duration: 0.12) : nil,
                           value: row == .synthesizing ? model.synthesisProgress : model.progressFraction)
        }
    }

    @ViewBuilder private var collapsedCenter: some View {
        switch row {
        case .synthesizing:
            Text(percentLabel)
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .foregroundStyle(theme.accent)
        case .ready where model.isPlaying:
            if let positionLabel {
                Text(positionLabel)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(theme.muted)
            } else {
                Text(percentLabel)
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(theme.muted)
            }
        default:
            Image(systemName: "play.fill")
                .font(.system(size: 15))
                .foregroundStyle(theme.ink)
        }
    }

    private var collapsedA11yValue: String {
        switch model.audioState {
        case .ready:
            let transport = model.isPlaying ? L10n.a11yPause : L10n.a11yPlay
            guard let positionLabel else {
                return transport + ", " + L10n.readerGenerating + ", " + percentLabel
            }
            return transport + ", " + positionLabel
        case .synthesizing: return L10n.readerGenerating + ", " + percentLabel
        case .locked: return L10n.readerSubscribeTitle
        case .notGenerated: return L10n.readerNotGeneratedTitle
        case .interrupted: return L10n.readerInterrupted
        case .failed(let msg): return msg
        case .idle: return ""
        }
    }

    private var expandedCapsule: some View {
        ZStack {
            switch row {
            case .ready: readyRow
            case .synthesizing: synthesizingRow
            case .locked: lockedRow
            case .preAudio: preAudioRow
            }
        }
        .animation(.easeInOut(duration: 0.22), value: row)
        .frame(width: expandedWidth, height: 64)
        .glassEffect(.regular, in: Capsule())
        .glassEffectID("player", in: glassNS)
    }

    private var readyRow: some View {
        HStack(spacing: 10) {
            accentCircleButton(model.isPlaying ? "pause.fill" : "play.fill",
                               a11y: model.isPlaying ? L10n.a11yPause : L10n.a11yPlay) {
                model.togglePlay()
            }
            Slider(value: seekBinding,
                   in: 0...max(1, model.duration),
                   enabledBounds: generatedBounds) {
                Text(L10n.a11yPosition)
            }
            .tint(theme.accent)
            .overlay {
                if model.isGenerating {
                    GeometryReader { geo in
                        let inset: CGFloat = 8
                        let usable = max(0, geo.size.width - inset)
                        let done = min(1, max(0, model.generatedFraction))
                        Capsule()
                            .fill(theme.bg.opacity(0.75))
                            .frame(width: usable * (1 - done), height: 4)
                            .position(x: inset + usable * (done + (1 - done) / 2),
                                      y: geo.size.height / 2)
                    }
                    .allowsHitTesting(false)
                }
            }
            .animation(.linear(duration: 0.3), value: model.generatedTime)
            if let positionLabel {
                Text(positionLabel)
                    .font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(theme.muted)
            }
            speedPill
            collapseButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private var synthesizingRow: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(theme.soft)
                ProgressView().tint(theme.muted)
            }
            .frame(width: 38, height: 38)
            VStack(spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.readerGenerating)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.ink)
                    Spacer()
                    Text(percentLabel)
                        .font(.system(size: 11.5)).monospacedDigit()
                        .foregroundStyle(theme.muted)
                }
                ProgressView(value: model.synthesisProgress)
                    .tint(theme.accent)
                    .animation(.linear(duration: 0.12), value: model.synthesisProgress)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.readerGenerating)
            .accessibilityValue(percentLabel)
            Button { model.cancelSynthesis() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.muted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(theme.soft))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.commonCancel)
        }
        .padding(.leading, 13)
        .padding(.trailing, 12)
    }

    private var lockedRow: some View {
        HStack(spacing: 0) {
            Button { app.showPaywall = true } label: {
                Text(L10n.readerSubscribeTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.accent)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.a11yMembership)
            collapseButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private var preAudioRow: some View {
        HStack(spacing: 10) {
            accentCircleButton("play.fill", a11y: L10n.a11yPlay) {
                model.startAudio()
            }
            Group {
                if case .failed(let msg) = model.audioState {
                    Text(msg)
                } else if model.audioState == .notGenerated {
                    Text(L10n.readerNotGeneratedTitle)
                } else if model.audioState == .interrupted {
                    Text(L10n.readerInterrupted)
                } else if model.audioState == .idle {
                    Text(L10n.readerIdleEstimate(model.estimatedNarrationMinutes))
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(theme.muted)
            .lineLimit(2)
            Spacer(minLength: 0)
            collapseButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    private func accentCircleButton(_ systemName: String, a11y: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17))
                .foregroundStyle(theme.onAccent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(theme.accent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11y)
    }

    private var speedPill: some View {
        Button {
            let i = Self.speedCycle.firstIndex(of: model.speed) ?? 0
            model.setSpeed(Self.speedCycle[(i + 1) % Self.speedCycle.count])
        } label: {
            Text("\(speedText(model.speed))×")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(theme.ink)
                .frame(minWidth: 44)
                .frame(height: 28)
                .overlay(Capsule().strokeBorder(theme.hair, lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.a11ySpeed)
        .accessibilityValue("\(speedText(model.speed))×")
    }

    private static let speedCycle: [Double] = [1.0, 1.25, 1.5, 0.75]

    private var collapseButton: some View {
        Button { isExpanded = false } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.muted)
                .frame(width: 30, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.a11yPlayerCollapse)
    }

    private var positionLabel: String? {
        guard !model.isGenerating else { return nil }
        return "−" + model.timeLabel(max(0, model.duration - model.currentTime))
    }

    private var percentLabel: String {
        "\(Int((model.synthesisProgress * 100).rounded()))%"
    }

    private var generatedBounds: ClosedRange<Double>? {
        guard model.isGenerating else { return nil }
        let total = max(1, model.duration)
        return 0...min(total, max(0.1, model.generatedTime))
    }

    private var seekBinding: Binding<Double> {
        Binding(get: { model.currentTime }, set: { model.seek(to: $0) })
    }

    private func speedText(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)
    }
}
