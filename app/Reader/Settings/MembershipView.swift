import SwiftUI
import RevenueCat
import RevenueCatUI

struct MembershipView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var showingPaywall = false
    @State private var restoring = false
    @State private var notice: String?
    @State private var info: CustomerInfo?

    private var entitlement: EntitlementInfo? {
        info?.entitlements[AppServices.entitlementID]
    }

    var body: some View {
        Group {
            if showingPaywall {
                PaywallView(displayCloseButton: true)
                    .onPurchaseCompleted { completed($0, otherwise: L10n.membershipPurchaseIncomplete) }
                    .onRestoreCompleted { completed($0, otherwise: L10n.membershipRestoreNone) }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            feature("waveform",
                                    L10n.membershipFeatureNarrationTitle, L10n.membershipFeatureNarrationBody)
                            feature("person.wave.2",
                                    L10n.membershipFeatureVoicesTitle, L10n.membershipFeatureVoicesBody)
                            feature("doc.viewfinder",
                                    L10n.membershipFeatureOCRTitle, L10n.membershipFeatureOCRBody)
                        }
                        .padding(.bottom, 16)
                    }
                    if entitlement?.isActive == true {
                        memberActions
                            .padding(.bottom, 12)
                    } else {
                        actions
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .presentationBackground(theme.bg)
        .presentationDragIndicator(.visible)
        .task {
            guard Purchases.isConfigured else { return }
            info = try? await Purchases.shared.customerInfo()
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text(L10n.readerSubscribeTitle)
                .font(Mincho.font(26)).foregroundStyle(theme.ink).tracking(1)
                .multilineTextAlignment(.center)
            if entitlement?.isActive != true {
                Text(L10n.readerSubscribeBody)
                    .font(.system(size: 15)).foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.top, 40).padding(.bottom, 24)
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(theme.accent)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.ink)
                Text(detail).font(.system(size: 14)).foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    private var actions: some View {
        VStack(spacing: 16) {
            if let notice {
                Text(notice)
                    .font(.system(size: 13)).foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
            }

            Button {
                guard Purchases.isConfigured else { notice = L10n.membershipUnavailable; return }
                showingPaywall = true
            } label: {
                Text(L10n.membershipSubscribe)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            Button {
                guard Purchases.isConfigured else { notice = L10n.membershipUnavailable; return }
                restore()
            } label: {
                Text(L10n.membershipRestore)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .opacity(restoring ? 0.4 : 1)
            .disabled(restoring)

            Text(L10n.narrationDisclaimer)
                .font(.system(size: 12)).foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.top, 16)
    }

    private var memberActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 15)).foregroundStyle(theme.accent)
                Text(L10n.membershipActive)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(theme.ink)
            }
            if let entitlement, let expiration = entitlement.expirationDate {
                let day = expiration.formatted(date: .long, time: .omitted)
                Text(entitlement.willRenew ? L10n.membershipRenews(day) : L10n.membershipExpires(day))
                    .font(.system(size: 13)).foregroundStyle(theme.muted)
            }
            if entitlement?.isSandbox == true {
                Text(L10n.membershipTestPurchase)
                    .font(.system(size: 12)).foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button { manageInAppStore() } label: {
                Text(L10n.membershipManageAppStore)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.bg)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24).padding(.top, 16)
    }

    private func completed(_ customerInfo: CustomerInfo, otherwise reason: String) {
        info = customerInfo
        guard customerInfo.entitlements[AppServices.entitlementID]?.isActive == true else {
            showingPaywall = false
            notice = reason
            return
        }
        app.entitlementTick += 1
        dismiss()
    }

    private func restore() {
        restoring = true
        notice = nil
        Task {
            defer { restoring = false }
            do {
                let restored = try await Purchases.shared.restorePurchases()
                if restored.entitlements[AppServices.entitlementID]?.isActive == true {
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

    private func manageInAppStore() {
        Task {
            do { try await Purchases.shared.showManageSubscriptions() }
            catch {
                openURL(info?.managementURL
                        ?? URL(string: "https://apps.apple.com/account/subscriptions")!)
            }
        }
    }
}
