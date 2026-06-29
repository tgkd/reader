# TestFlight with working subscriptions — setup guide

How to ship a TestFlight build where **subscriptions + TTS actually work** (real
StoreKit purchase → RevenueCat entitlement → Worker 200 → narration plays).

**Why this is needed:** the simulator uses RevenueCat's **Test Store** (`test_` key),
which is skipped on real devices (it crashes against real StoreKit — see
`AppServices.configureRevenueCat`). A device/TestFlight build needs a real **App
Store `appl_` key** + a real **auto-renewable subscription** in App Store Connect.

**Current state (where you are):**
- App Store Connect: the app **Yomi — Japanese Reader** exists; subscription
  **`app.reader.app.monthly`** is created in group *membership* but shows **Missing Metadata**
  → needs localization (§A).
- RevenueCat (project **reader**): the **`reader Pro`** entitlement, a **Test Store** product,
  and the **default** offering exist — but there is **no App Store app yet**, so the build still
  carries a `test_` SDK key. Remaining: bind the App Store side (§B), then swap the key (§C).

**Already done (no action needed):**
- Prod Worker verifies the **reader** RevenueCat project (`REVENUECAT_PROJECT_ID_READER`
  = `<reader project id>`) with a v2 secret key, and has `ELEVENLABS_KEY`. So once a real
  subscriber's entitlement lands in the reader project, the Worker returns 200.
- The app reads `WorkerBaseURL` + `RevenueCatKey` from the Info.plist (baked from the
  gitignored `Signing.xcconfig`: `WORKER_HOST` is set; you'll add `REVENUECAT_KEY`).
- The gate (`isSubscribed` / `reader Pro`), paywall (`PaywallView`), and unlock-reload
  are wired and verified in the sim. The paywall is **crash-guarded** when RevenueCat is
  unconfigured (a `test_`/empty key on a real device) — it shows a dismissable fallback instead
  of `fatalError`-ing on `Purchases.shared`.

Identifiers used below: bundle id **`app.reader.app`**, Team **`<your Team ID — from Signing.xcconfig>`**,
RevenueCat project **reader (`<reader project id>`)**, entitlement **`reader Pro`**.

---

## A. App Store Connect

The app record (3) and the subscription (4) already exist — the **only remaining ASC work is
the Paid Apps Agreement (1) and clearing the subscription's "Missing Metadata"** (the
localization in 4). Steps 2–3 are kept for reference.

1. **Paid Applications Agreement** — App Store Connect → Business → Agreements. It
   **must be Active**, or subscription products never load (silent failure). Requires
   banking + tax info.
2. **Register the App ID** — developer.apple.com → Certificates, IDs & Profiles →
   Identifiers → `+` → App IDs → bundle id `app.reader.app`. (Xcode automatic signing
   can also create it on first archive.) In-App Purchase is enabled by default.
3. **Create the app** — App Store Connect → Apps → `+` → New App:
   - Platform: iOS · Bundle ID: `app.reader.app` · Name: e.g. `Yomi` (must be unique
     on the store) · Primary language · SKU: any (e.g. `yomi-reader`).
4. **Create the subscription** — your app → Monetization → **Subscriptions**:
   - New **Subscription Group**: e.g. `Yomi Membership`.
   - Add **auto-renewable subscription**:
     - Reference Name: `Monthly`
     - **Product ID**: `app.reader.app.monthly` (unique, immutable — write it down)
     - Duration: 1 Month · Price: $9.99
     - Add a localized **display name + description** (required to leave Draft).
   - Get it to at least **"Ready to Submit"** (it's purchasable in sandbox/TestFlight
     without full review).

## B. RevenueCat (project: reader)

**The key idea:** RevenueCat's **Test Store** (what you have now → the `test_` key) is
sandbox-only and unrelated to Apple. To take real money you add a **separate App Store app**
inside the same project; the bridge is an In-App Purchase `.p8`. Leave the Test Store product
attached for the sim — just **add the App Store product alongside it** on the entitlement (4)
and the offering (5).

1. **In-App Purchase key** — App Store Connect → Users and Access → **Integrations →
   In-App Purchase** → generate a key, download the `.p8`. (RevenueCat needs this to
   validate App Store receipts.)
2. **Add an App Store app** — RevenueCat → Project settings → **Apps → + New** →
   **App Store** (not Test Store):
   - Bundle ID `app.reader.app`; upload the In-App Purchase `.p8` (key id + issuer id).
   - This generates the **`appl_…` public SDK key** (Project → API keys → SDK keys).
3. **Import the product** — Product catalog → **Products** → import from App Store →
   select `app.reader.app.monthly` (or add it manually with that exact id).
4. **Attach to the entitlement** — Product catalog → Entitlements → **`reader Pro`** →
   Attach products → add `app.reader.app.monthly`. (Keep or remove the Test Store
   "Monthly"; the App Store one is what device purchases grant.)
5. **Offering + paywall** — Product catalog → **Offerings**: ensure the **current**
   offering has a package containing `app.reader.app.monthly`, and your **"pay"**
   paywall is attached to that offering. (`PaywallView()` shows the current offering's
   paywall; if the package isn't the App Store product, the paywall can't purchase on
   device.)

## C. App config

1. In **`app/Signing.xcconfig`** (gitignored) set the App Store key:
   ```
   REVENUECAT_KEY = appl_xxxxxxxxxxxxxxxxxxxxxxxx
   ```
   (Replaces the `test_…` Test Store key. The device gate passes `appl_` keys; the sim
   still works with whatever key is here.)
2. Bump the build number for each upload — `app/project.yml` →
   `CURRENT_PROJECT_VERSION` (and `MARKETING_VERSION` when the version changes), then
   `cd app && xcodegen generate`.
3. `WORKER_HOST` is already set; nothing else to change. Signing stays Automatic with
   `DEVELOPMENT_TEAM = <your Team ID — from Signing.xcconfig>`.

## D. Archive & upload

Easiest via Xcode:
1. Open `app/Reader.xcodeproj`, scheme **Reader**, destination **Any iOS Device**.
2. **Product → Archive** (Release config — `#if DEBUG` hooks are stripped, so no test
   shims ship).
3. Organizer → **Distribute App → App Store Connect → Upload** (Xcode handles the
   distribution cert + App Store provisioning profile via Automatic signing +
   `-allowProvisioningUpdates`).

CLI alternative (needs an App Store Connect API key):
```bash
cd app
xcodebuild -project Reader.xcodeproj -scheme Reader -configuration Release \
  -archivePath build/Reader.xcarchive -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath build/Reader.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export \
  -allowProvisioningUpdates
xcrun altool --upload-app -f build/export/Reader.ipa -t ios \
  --apiKey <KEY_ID> --apiIssuer <ISSUER_ID>
```
(`ExportOptions.plist`: `method = app-store-connect`, `teamID = <your Team ID — from Signing.xcconfig>`,
`signingStyle = automatic`. I can generate this on request.)

## E. TestFlight + sandbox purchase

1. After processing (~5–30 min), the build appears in **TestFlight**.
2. **Internal testing** (you / up to 100 internal testers) needs **no beta review** —
   add yourself, install via the TestFlight app. (External testers need a one-time
   beta review.)
3. **Purchasing on TestFlight uses the sandbox** (free, accelerated renewals — a
   "1 month" sub renews in ~5 min, then expires). If prompted, sign in with a **Sandbox
   Apple Account** (App Store Connect → Users and Access → Sandbox → Testers), or set it
   under iOS Settings → Developer / App Store → Sandbox Account.
4. Flow to verify: open a book → **"Listen with Membership"** → View Membership →
   **Continue** → sandbox purchase → paywall dismisses → reader reloads → **narration
   plays** (the appUserID now has `reader Pro` in the reader project → Worker 200).

## Verification checklist
- [ ] Paid Apps Agreement Active; app record + subscription exist; sub "Ready to Submit".
- [ ] RevenueCat has an **App Store** app (not just Test Store) + IAP key uploaded.
- [ ] `app.reader.app.monthly` imported, attached to `reader Pro`, in the current offering with the "pay" paywall.
- [ ] `REVENUECAT_KEY = appl_…` in `Signing.xcconfig`; build number bumped.
- [ ] Release archive uploaded; TestFlight build installs and **launches without crashing**.
- [ ] Sandbox purchase grants `reader Pro` → narration plays on device.

## Gotchas
- **No Paid Apps Agreement** → products silently fail to load (paywall shows empty/error).
- **No IAP key in RevenueCat** → purchases complete but never grant the entitlement.
- **App Store product not attached to `reader Pro`** → purchase succeeds, but `isSubscribed`
  stays false and the Worker 403s.
- **Wrong offering/paywall** → the paywall can't find a purchasable package on device.
- TestFlight IAP is **sandbox** — free, but renews/expires fast; re-purchase as needed.
- Increment **CURRENT_PROJECT_VERSION** every upload or App Store Connect rejects it.
