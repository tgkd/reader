import SwiftUI
import RevenueCat
import RevenueCatUI

/// The membership screen for non-subscribers, presented as a sheet from the
/// Library star, the reader's locked pill, and Settings. Leads with what
/// Membership adds, then Subscribe (the RevenueCat paywall) and Restore
/// Purchases. Renders in full even when RevenueCat is unconfigured — the
/// buttons surface the unavailable notice instead of touching
/// `Purchases.shared` (which traps on a misconfigured build).
struct MembershipView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var showingPaywall = false
    @State private var restoring = false
    /// Inline outcome line under the buttons: restore found nothing, restore
    /// failed, or the build has no RevenueCat key.
    @State private var notice: String?

    var body: some View {
        // Subscribe swaps the paywall IN PLACE of the features list rather than
        // stacking a second sheet on this one — a single surface, and the
        // paywall's loading/error states are always visible. The paywall's own
        // close button dismisses the whole membership sheet.
        Group {
            if showingPaywall {
                PaywallView(displayCloseButton: true)
                    .onPurchaseCompleted { _ in
                        app.entitlementTick += 1
                        dismiss()
                    }
                    .onRestoreCompleted { _ in
                        app.entitlementTick += 1
                        dismiss()
                    }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header
                        feature("waveform",
                                L10n.membershipFeatureNarrationTitle, L10n.membershipFeatureNarrationBody)
                        feature("person.wave.2",
                                L10n.membershipFeatureVoicesTitle, L10n.membershipFeatureVoicesBody)
                        feature("doc.viewfinder",
                                L10n.membershipFeatureOCRTitle, L10n.membershipFeatureOCRBody)
                        actions
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .presentationBackground(theme.bg)
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.readerSubscribeTitle)
                .font(Mincho.font(22)).foregroundStyle(theme.ink).tracking(1)
            Text(L10n.readerSubscribeBody)
                .font(.system(size: 14)).foregroundStyle(theme.muted)
        }
        .padding(.horizontal, 24).padding(.top, 26).padding(.bottom, 12)
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19))
                .foregroundStyle(theme.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(theme.ink)
                Text(detail).font(.system(size: 14)).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var actions: some View {
        VStack(spacing: 14) {
            Button {
                guard Purchases.isConfigured else { notice = L10n.membershipUnavailable; return }
                showingPaywall = true
            } label: {
                Text(L10n.membershipSubscribe)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                guard Purchases.isConfigured else { notice = L10n.membershipUnavailable; return }
                restore()
            } label: {
                Text(L10n.membershipRestore)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .opacity(restoring ? 0.4 : 1)
            .disabled(restoring)

            if let notice {
                Text(notice)
                    .font(.system(size: 13)).foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24).padding(.top, 20)
    }

    /// Restore outside the paywall: an entitlement coming back closes the screen;
    /// a restore that yields none (or fails) reports inline instead.
    private func restore() {
        restoring = true
        notice = nil
        Task {
            defer { restoring = false }
            do {
                let info = try await Purchases.shared.restorePurchases()
                if info.entitlements[AppServices.entitlementID]?.isActive == true {
                    app.entitlementTick += 1
                    dismiss()
                } else {
                    notice = L10n.membershipRestoreNone
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }
}
