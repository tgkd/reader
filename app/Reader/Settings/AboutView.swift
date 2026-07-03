import SwiftUI

/// The About screen: app mark + version, product links (website / terms /
/// privacy / contact), and the attributions the bundled data requires
/// (JMdict via EDRDG, MeCab + IPADic), plus the AI-accuracy note. Presented
/// as a sheet from Settings.
struct AboutView: View {
    @Environment(\.theme) private var theme

    private static let website = URL(string: "https://yomi.thetango.org")!
    private static let terms = URL(string: "https://yomi.thetango.org/terms")!
    private static let privacy = URL(string: "https://yomi.thetango.org/privacy")!
    private static let contact = URL(string: "mailto:jisho_ai@proton.me")!
    private static let jmdict = URL(string: "https://www.edrdg.org/wiki/index.php/JMdict-EDICT_Dictionary_Project")!

    /// Marketing version + build from the bundle (never hardcoded).
    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                Text(L10n.aboutDescription)
                    .font(.system(size: 14)).foregroundStyle(theme.muted)
                    .padding(.horizontal, 24).padding(.bottom, 8)

                sectionHeader(L10n.aboutLinks)
                linkRow(L10n.aboutWebsite, url: Self.website)
                linkRow(L10n.aboutTerms, url: Self.terms)
                linkRow(L10n.aboutPrivacy, url: Self.privacy)
                linkRow(L10n.aboutContact, url: Self.contact)

                sectionHeader(L10n.aboutSources)
                linkRow("JMdict", url: Self.jmdict)
                footnote(L10n.aboutSourcesNote)
                footnote(L10n.aboutAINote)
            }
            .padding(.bottom, 24)
        }
    }

    /// App mark + name + bundle version, centered — the identity block the
    /// reference About screens leave out.
    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(theme.accent).frame(width: 9, height: 9)
                Text(L10n.wordmark).font(Mincho.font(26)).foregroundStyle(theme.ink).tracking(3)
            }
            Text("\(L10n.aboutVersion) \(version)")
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(theme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28).padding(.bottom, 18)
    }

    private func linkRow(_ label: String, url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(label).font(.system(size: 16)).foregroundStyle(theme.ink)
                Spacer(minLength: 12)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.muted)
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 24)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5)).foregroundStyle(theme.muted)
            .padding(.horizontal, 24).padding(.top, 10)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium)).tracking(1.5).textCase(.uppercase)
            .foregroundStyle(theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 6)
    }
}
