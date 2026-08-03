import SwiftUI

struct ImportProgressView: View {
    let activity: ImportActivity
    let cancel: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            phaseIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(activity.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let percent {
                        Text(percent)
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(theme.muted)
                    }
                }

                ProgressView(value: activity.fraction ?? 0)
                    .tint(theme.accent)
                    .opacity(activity.fraction == nil ? 0.35 : 1)
                    .animation(.linear(duration: 0.12), value: activity.fraction)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(activity.fileName)
            .accessibilityValue(accessibilityValue)

            if activity.canCancel {
                Button(action: cancel) {
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
        }
        .padding(.leading, 13)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity)
        .frame(height: 76)
        .glassEffect(.regular, in: Capsule())
    }

    @ViewBuilder private var phaseIcon: some View {
        ZStack {
            Circle().fill(activity.phase == .completed ? theme.accent : theme.soft)
            if activity.phase == .completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.onAccent)
            } else if activity.phase == .awaitingOCR {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.accent)
            } else {
                ProgressView().tint(theme.muted)
            }
        }
        .frame(width: 38, height: 38)
    }

    private var status: String {
        switch activity.phase {
        case .preparing:
            return L10n.importPreparing
        case .parsing:
            if let completed = activity.completed, let total = activity.total {
                return L10n.importParsing(completed, total)
            }
            return L10n.importParsing
        case .inspecting:
            return L10n.importInspecting
        case .awaitingOCR:
            return L10n.importAwaitingOCR
        case .recognizing:
            if let completed = activity.completed, let total = activity.total {
                return L10n.importRecognizing(completed, total)
            }
            return L10n.importPreparing
        case .saving:
            return L10n.importSaving
        case .completed:
            return L10n.importCompleted
        }
    }

    private var percent: String? {
        guard let fraction = activity.fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))%"
    }

    private var accessibilityValue: String {
        if let percent { return status + ", " + percent }
        return status
    }
}
