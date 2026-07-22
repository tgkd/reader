import SwiftUI

/// The collapsible audio player: a floating glass circle (bottom-right) that
/// morphs into a full-width capsule. The morph is the system Liquid Glass
/// transition — two views sharing a `glassEffectID` inside one
/// `GlassEffectContainer` — not a hand-animated frame.
///
/// Every audio state starts collapsed; tapping the circle only ever expands it
/// (it never starts playback or paid synthesis). The circle shows a thin
/// progress ring — playback position when audio is ready, generation progress
/// while synthesizing — and, while playing, a tiny remaining-time readout.
struct PlayerView: View {
    let model: ReaderModel
    let expandedWidth: CGFloat

    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @State private var isExpanded = false
    @Namespace private var glassNS

    /// The expanded capsule's row, folded from `AudioState` so that a
    /// `.failed` message change doesn't re-trigger the row cross-fade.
    private enum Row: Equatable {
        case ready, synthesizing, locked, preAudio

        init(_ state: ReaderModel.AudioState) {
            switch state {
            case .ready: self = .ready
            case .synthesizing: self = .synthesizing
            case .locked: self = .locked
            case .idle, .notGenerated, .failed: self = .preAudio
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

    // MARK: - Collapsed circle

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

    /// 3 pt ring just inside the circle's edge. Playback updates are raw — the
    /// value already advances every display frame, and an implicit animation
    /// would lag seeks; the 10 Hz synthesis estimate gets a short linear ease.
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
            Text(remainingLabel)
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(theme.muted)
        default:
            Image(systemName: "play.fill")
                .font(.system(size: 15))
                .foregroundStyle(theme.ink)
        }
    }

    private var collapsedA11yValue: String {
        switch model.audioState {
        case .ready: return (model.isPlaying ? L10n.a11yPause : L10n.a11yPlay) + ", " + remainingLabel
        case .synthesizing: return L10n.readerGenerating + ", " + percentLabel
        case .locked: return L10n.readerSubscribeTitle
        case .notGenerated: return L10n.readerNotGeneratedTitle
        case .failed(let msg): return msg
        case .idle: return ""
        }
    }

    // MARK: - Expanded capsule

    /// Rows swap structurally so inactive ones leave the accessibility tree —
    /// opacity/accessibilityHidden gating leaks phantom elements through the
    /// glass-hosted subtree. The default `.opacity` transition still cross-fades
    /// the synthesizing→ready hand-off in place instead of jumping.
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

    /// Audio ready: play beside the native scrubber, remaining time, and the
    /// speed pill. Chapter switching lives in the header's title capsule (and
    /// the lock screen), never here.
    private var readyRow: some View {
        HStack(spacing: 10) {
            accentCircleButton(model.isPlaying ? "pause.fill" : "play.fill",
                               a11y: model.isPlaying ? L10n.a11yPause : L10n.a11yPlay) {
                model.togglePlay()
            }
            Slider(value: seekBinding, in: 0...max(1, model.duration)) {
                Text(L10n.a11yPosition)
            }
            .tint(theme.accent)
            Text(remainingLabel)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(theme.muted)
            speedPill
            collapseButton
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
    }

    /// Speech generation in flight: native spinner, label with a live percent,
    /// and a thin determinate bar. No collapse control — cancel is the one
    /// deliberate action here, and the progress should stay visible.
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

    /// Free tier: audio is gated. One centered action that opens the paywall.
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

    /// Subscribed but audio not generated yet (or a prior attempt failed): Play
    /// synthesizes on tap — the row then cross-fades into the generating one —
    /// and a short status explains the failed / no-audio case.
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

    // MARK: - Shared controls

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

    /// Tap-to-cycle speed control (1× → 1.25× → 0.75×). `?? 0` self-heals a
    /// persisted speed that fell out of the cycle.
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

    private static let speedCycle: [Double] = [1.0, 1.25, 0.75]

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

    // MARK: - Derived labels

    private var remainingLabel: String {
        "−" + model.timeLabel(max(0, model.duration - model.currentTime))
    }

    private var percentLabel: String {
        "\(Int((model.synthesisProgress * 100).rounded()))%"
    }

    /// Two-way bridge for the native scrubber: reads the playhead, writes it
    /// through `seek`.
    private var seekBinding: Binding<Double> {
        Binding(get: { model.currentTime }, set: { model.seek(to: $0) })
    }

    private func speedText(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)
    }
}
