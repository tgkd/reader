import SwiftUI

struct PlayerView: View {
    let model: ReaderModel
    let expandedWidth: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var isExpanded = false
    @GestureState private var speedDrag = SpeedDrag()
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
    private var showSpeed: Bool { speedDrag.isActive && model.chromeVisible }

    private struct SpeedDrag: Equatable {
        var initialIndex: Int?
        var isActive = false
        var translation: CGFloat = 0
    }

    var body: some View {
        GlassEffectContainer {
            ZStack(alignment: .bottomTrailing) {
                if isExpanded && showSpeed && row == .ready {
                    speedPanel
                        .offset(y: -72)
                        .transition(.scale(scale: 0.86, anchor: .bottomTrailing)
                            .combined(with: .opacity))
                }
                if isExpanded {
                    expandedCapsule
                } else {
                    collapsedCircle
                }
            }
        }
        .animation(.smooth(duration: 0.38), value: isExpanded)
        .animation(.smooth(duration: 0.3), value: showSpeed)
        .onChange(of: speedDrag) { _, drag in
            guard drag.isActive, let initialIndex = drag.initialIndex else { return }
            selectSpeed(at: initialIndex + Int((drag.translation / 24).rounded()))
        }
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
                        let played = model.duration > 0
                            ? min(1, max(0, model.currentTime / model.duration)) : 0
                        let start = max(inset + usable * done,
                                        inset + usable * played + Self.thumbClearance)
                        let end = inset + usable
                        if end > start {
                            Capsule()
                                .fill(theme.bg.opacity(0.75))
                                .frame(width: end - start, height: 4)
                                .position(x: (start + end) / 2, y: geo.size.height / 2)
                        }
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
        Text("\(speedText(model.speed))×")
            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            .foregroundStyle(showSpeed ? theme.onAccent : theme.ink)
            .frame(width: 44, height: 28)
            .background(Capsule().fill(showSpeed ? theme.accent : .clear))
            .overlay(Capsule().strokeBorder(showSpeed ? .clear : theme.hair, lineWidth: 1))
            .frame(height: 44)
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.25, maximumDistance: 12)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($speedDrag) { value, state, _ in
                        if state.initialIndex == nil {
                            state.initialIndex = ReaderModel.supportedSpeeds.firstIndex(of: model.speed)
                        }
                        if case .second(true, let drag) = value {
                            state.isActive = true
                            state.translation = drag?.translation.width ?? 0
                        }
                    }
            )
            .sensoryFeedback(.selection, trigger: model.speed)
            .sensoryFeedback(.impact(weight: .light), trigger: showSpeed) { _, open in open }
            .accessibilityElement()
            .accessibilityLabel(L10n.a11ySpeed)
            .accessibilityValue("\(speedText(model.speed))×")
            .accessibilityAdjustableAction { direction in
                let index = ReaderModel.supportedSpeeds.firstIndex(of: model.speed) ?? 1
                switch direction {
                case .increment: selectSpeed(at: index + 1)
                case .decrement: selectSpeed(at: index - 1)
                default: break
                }
            }
    }

    private func selectSpeed(at index: Int) {
        let speeds = ReaderModel.supportedSpeeds
        let speed = speeds[min(speeds.count - 1, max(0, index))]
        if speed != model.speed { model.setSpeed(speed) }
    }

    private var speedPanel: some View {
        SpeedSlider(speeds: ReaderModel.supportedSpeeds, value: model.speed)
            .padding(4)
            .frame(width: max(190, expandedWidth * 0.55), height: 48)
            .glassEffect(.regular, in: Capsule())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

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

    private static let thumbClearance: CGFloat = 22

    private var generatedBounds: ClosedRange<Double>? {
        guard model.isGenerating else { return nil }
        let total = max(1, model.duration)
        return 0...min(total, max(0.1, model.generatedTime))
    }

    private var seekBinding: Binding<Double> {
        Binding(get: { model.currentTime }, set: { model.seek(to: $0) })
    }

    private func speedText(_ v: Double) -> String {
        SpeedSlider.label(v)
    }
}
