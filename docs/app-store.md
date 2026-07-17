# App Store listing — Yomi (読み)

Source of truth for the App Store Connect submission. Copy the fields below into
the listing verbatim; character budgets are noted so nothing gets truncated. Keep
the voice understated and reading-first — no emoji, no hype (matches the site,
About screen, and `L10n`).

- **Bundle / SKU:** `app.reader.app` (Xcode target `Reader`)
- **Display name (on device):** Yomi
- **Website:** https://yomi.thetango.org · **Support:** jisho_ai@proton.me
- **Version at launch:** 1.0 · **Min iOS:** 26.0 · **Devices:** iPhone (iPad if enabled)
- **Primary category:** Books · **Secondary:** Education
- **Age rating:** 4+
- **Price:** Free to download. One auto-renewing subscription — **Membership**
  (`app.reader.app.monthly`, `reader Pro` entitlement). Set the price tier in App
  Store Connect / RevenueCat. No free trial configured.

---

## 1. Metadata fields

**App name** (≤30 chars) — pick one:
- `Yomi: Japanese Reader` (21)  ← recommended
- `Yomi — Read Japanese Books` (26)

**Subtitle** (≤30 chars) — pick one:
- `Read Japanese books aloud` (25)  ← recommended
- `Word-synced Japanese reading` (28)

**Keywords** (≤100 chars, comma-separated, no spaces after commas, no words already
in the name/subtitle, no "app"):

```
furigana,kanji,read aloud,narration,epub,tategaki,ocr,jlpt,vocabulary,dictionary,audiobook,learn
```

**Promotional text** (≤170 chars, editable anytime without review):

```
Import your own Japanese books and hear them read aloud with a moving word-by-word highlight — furigana, tap-to-define, and vertical text included.
```

---

## 2. Text about the app (Description — ≤4000 chars)

> This is the App Store **Description** field. It deliberately does not quote a
> price — Apple shows that from the subscription. Keep the free/Membership split
> exactly as written; it's what App Review checks against.

```
Yomi turns the Japanese books you already own into a reading experience built for
learners and readers alike. Import an EPUB, PDF, or plain-text file and read it the
way it was meant to be read — vertical or horizontal, with furigana over the kanji
and a dictionary a tap away.

Press play, and Yomi reads the chapter aloud while a highlight moves word by word,
in time with the narration. It's the single feature that ties everything together:
you hear the sentence and see exactly where you are in it — no guessing which word
is being spoken.

READING, DONE RIGHT
• Furigana readings sit above the kanji — on when you want them, off when you don't.
• Tap any word for its meaning and reading, with a button to hear it pronounced.
• Vertical (縦書き) and horizontal (横書き) text, laid out like a real book.
• Four themes for any light: paper, white, sepia, and night.
• Adjustable font, size, and reading orientation.

NARRATION THAT STAYS IN SYNC
• AI narration with a word-by-word highlight locked to the audio.
• Adjustable playback speed.
• Background playback with lock-screen and Control Center controls — skip chapters
  without unlocking your phone.
• Once a chapter is narrated it's saved on your device and replays offline, free.

YOUR OWN LIBRARY
• Import EPUB, PDF, and TXT files, or open them straight into Yomi from Files, Mail,
  or the share sheet.
• Reading order, chapters, and titles are pulled from the book itself.
• Scanned or image-only books with no text layer are recognized by AI so you can
  read and hear them too.

PRIVATE BY DESIGN
• No accounts, no ads, no analytics, no tracking.
• Your books stay on your device. Reading them — furigana and dictionary lookups
  included — sends nothing anywhere.
• Text leaves your device only when you ask for a paid AI feature (narration or
  scanned-text recognition), and only for that request.

FREE, AND WHAT MEMBERSHIP ADDS
Reading is free: import EPUB, TXT, and born-digital PDF books and read them with
furigana, tap-to-define, themes, and vertical text at no cost. Membership adds the
paid AI features — spoken word-synced narration and reading scanned/image-only
books — and unlocks the narration-voice picker.

—
Dictionary data from JMdict, property of the Electronic Dictionary Research and
Development Group, used under its licence. Text analysis uses MeCab with the IPADic
dictionary. Narration, scanned-text recognition, and readings are AI-generated and
may contain mistakes.
```

**Subscription disclosure** (append to the Description if not covered by the
standard StoreKit sheet; required when you have an auto-renewing subscription):

```
Membership is an auto-renewing subscription billed monthly through your Apple
Account. It renews automatically unless turned off at least 24 hours before the
period ends; manage or cancel it in Settings > Apple Account > Subscriptions.
Terms: https://yomi.thetango.org/terms · Privacy: https://yomi.thetango.org/privacy
```

---

## 3. App features list for App Store screenshots

> **Final rendered screenshots live in `docs/appstore/`** (`6.9/` = 1320×2868,
> the required upload size; `6.5/` = 1284×2778) — exported from the Claude
> design project via `docs/appstore-screens-prompt.md`. The table below is the
> original slide plan; the shipped set is the 5-slide cut in `docs/appstore/`.

Eight slides, ordered strongest-first. Each is a short headline + one supporting
line. Screen 1 is the one that has to sell the app on its own. Localize headlines
for the Japanese storefront if you ship a `ja` listing; keep the on-screen book
content Japanese in every locale.

| # | Screenshot to capture | Headline | Supporting line |
|---|---|---|---|
| 1 | Reader mid-playback, one word highlighted, pill player visible | **Read Japanese, word by word** | AI narration highlights each word as it's spoken. |
| 2 | A paragraph with furigana over the kanji | **Furigana over every kanji** | Readings where you want them — one tap to turn them off. |
| 3 | Tap-to-define card open on a word | **Tap any word to define it** | Meaning, reading, and pronunciation, built in. |
| 4 | Tategaki (vertical) page | **Vertical or horizontal** | 縦書き and 横書き, laid out like a real book. |
| 5 | Theme switch — night or sepia | **A theme for any light** | Paper, white, sepia, and night. |
| 6 | Library with an imported book + import sheet | **Bring your own books** | EPUB, PDF, and TXT — even scanned pages, read by AI. |
| 7 | Lock screen showing Now Playing controls | **Listen anywhere** | Background playback with lock-screen controls. |
| 8 | Settings / privacy-forward frame | **Your books stay yours** | No accounts, no ads, no tracking. |

Capture on the required sizes (6.9" iPhone at minimum; add 6.5" if targeting older
devices). `scripts/uitest/smoke.sh` can drive the reader on a booted simulator and
drop screenshots for slides 1–5.

---

## 4. What's New (version 1.0)

```
First release. Import your Japanese EPUB, PDF, and TXT books and read them with
furigana, tap-to-define, and vertical text — then hear them read aloud with a
word-by-word highlight that stays in sync with the narration.
```

---

## 5. App privacy (nutrition label)

Mirror the Privacy Policy (yomi.thetango.org/privacy). Recommended answers:

- **Data used to track you:** None.
- **Data linked to you:** None.
- **Data not linked to you — Purchases:** purchase history, via RevenueCat/Apple,
  used for App Functionality only (verifying an active Membership). No advertising.
- Everything else (books, reading activity, contacts, location, identifiers,
  usage/diagnostics): **not collected.** No accounts, no analytics SDK.

Note for the reviewer of the label: chapter text and scanned-page images are sent
to third-party AI providers **only** to fulfill a user-requested paid feature and
are not retained as content on our servers — this is processing, not collection.

---

## 6. Notes for App Review

```
Yomi is free to read imported books; a monthly Membership adds two paid AI
features — spoken word-synced narration, and reading scanned/image-only books via
text recognition.

The library starts empty — users import their own books. Sample public-domain
Japanese books for testing (open each URL in Safari on the device, then share
sheet → Yomi, or tap Open in "Yomi"):
- EPUB (free reading): https://yomi.thetango.org/samples/kokoro.epub
- PDF (free reading): https://yomi.thetango.org/samples/ginga-tetsudo-no-yoru.pdf
- Scanned PDF (tests the paid AI text recognition):
  https://yomi.thetango.org/samples/ginga-tetsudo-no-yoru-scanned.pdf

To test the paid features, please use a StoreKit sandbox account to purchase
Membership. The Membership screen is at Settings → Membership; pressing Play on a
chapter without Membership opens the same screen. After subscribing:
1. Import the EPUB above and press Play on a chapter — this generates and plays
   word-synced narration with a moving highlight.
2. Import the scanned PDF above and confirm the "read with AI" prompt to see
   text recognition.

No login or account is required. The app collects no personal data and contains no
advertising. Subscriptions are handled by Apple via RevenueCat.

Support: jisho_ai@proton.me
```

---

## 7. Pre-submission checklist

- [ ] Screenshots captured at every required device size (slides above).
- [ ] Subscription **Membership** created in App Store Connect, price tier set,
      localized name/description added, and attached to this version.
- [ ] Subscription group + "Privacy Policy" and "Terms of Use (EULA)" URLs set on
      the app and the subscription (Apple requires both for auto-renewing IAP).
- [ ] RevenueCat paywall template shows functional Privacy Policy and Terms links
      (guideline 3.1.2 requires them on the purchase screen itself, not just in
      App Store Connect — the Membership sheet has none of its own).
- [ ] Privacy nutrition label filled in per §5.
- [ ] Support URL (yomi.thetango.org) and marketing URL reachable; Terms/Privacy
      pages live.
- [ ] Build uploaded via Xcode Cloud (build number is cloud-managed — see CLAUDE.md).
- [ ] Age rating questionnaire completed → 4+.
- [ ] Export compliance: uses only standard HTTPS/TLS (exempt).
```
