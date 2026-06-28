# reader — Japanese reader with synced audio (iOS)

Read Japanese text with word-synced TTS highlighting, furigana, and tap-to-define.
Standalone app (working name **Yomi**); the sibling Jisho apps are referenced for
code patterns only, not reused as a base.

**Docs:** [`CLAUDE.md`](CLAUDE.md) — working state, decisions, invariants, reuse
map, full roadmap, build/run + DEBUG hooks. [`docs/char-token-sync.md`](docs/char-token-sync.md)
— the char→token mapping algorithm (read before touching `CharTokenMapper`).
[`docs/design-prompt.md`](docs/design-prompt.md) — the prompt that produced the Yomi design.

## The hard part

TTS gives **per-character** timings; Japanese has no spaces, so word boundaries
must come from a tokenizer and the character timings folded onto token spans. That
char→token mapping was the only genuinely hard risk, so it was de-risked first.
One MeCab pass is the single source of truth for **sync spans + furigana readings +
dictionary base forms** — never a second segmenter.

Stack: ElevenLabs `with-timestamps` (audio + char timings, via the `aiwork`
Cloudflare Worker) · MeCab+IPADic (tokenize / furigana / lemma) · two-pointer
tolerant mapping · custom CoreText reader (ruby + vertical/horizontal + synced
highlight) · on-disk content-addressed cache · jisho→SQLite tap-to-define.

## Status

| Area | What | State |
|---|---|---|
| Sync pipeline | `CharTokenMapper` + MeCab + real ElevenLabs fixtures | ✅ green — 41 tests, 100% coverage |
| Product app | Library / Reader / Dictionary, 3 themes, tategaki + yokogaki, tap-to-define — built to the **Yomi** design | ✅ built & sim-verified |
| i18n | `L10n` + en/ja dicts; chrome localizes, content stays JP | ✅ verified |
| Caching | `DiskAudioStore` (mp3 + alignment by content hash) + persisted library | ✅ verified |
| Progress | `ReadingProgress` writeback + resume; library 未読/N%/読了 track real reading | ✅ sim-verified |
| TTS API | aiwork Worker `POST /tts/aligned` + `WorkerTTSService` | ✅ route deployed; live test needs a subscribed user |
| Dictionary | tap-to-define over a compact (43 MB) jisho DB | ✅ real — `SQLiteDictionaryService`, sim-verified |
| Ingestion | EPUB (spine) / PDF / .txt import + chunker + alignment stitch + chapter nav | ✅ Phase 7 done — EPUB sim-verified end-to-end |

`ReaderCore/` is a dependency-light SwiftPM package (MeCab-Swift only) holding all
non-UI logic **and the service contracts**; it builds for macOS, so the whole
mapper + tokenizer + fixture pipeline is verifiable with `swift test`. The app
target (`Reader`) is for the visual/perceptual checks.

## Run

```bash
cd ReaderCore && swift test            # 41 pass — run after any ReaderCore change

# Build the compact tap-to-define DB once (gitignored output), then the app:
scripts/build-compact-dict.sh          # jisho-seed.db → app/Reader/Resources/jisho-compact.db

# Product app (Reader / Yomi)
cp app/Signing.xcconfig.example app/Signing.xcconfig   # gitignored; set your Team ID (required before xcodegen)
cd app && xcodegen generate
xcodebuild -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
# Deterministic screenshot via DEBUG hooks (e.g. tategaki, highlight at 1.7s):
#   SIMCTL_CHILD_READER_SEED=1 SIMCTL_CHILD_READER_OPEN=0 SIMCTL_CHILD_READER_ORI=tate SIMCTL_CHILD_READER_SEEK=1.7

# Capture ElevenLabs fixtures (your key in reader/.env as ELEVEN_KEY):
node scripts/capture-alignment.mjs "吾輩は猫である。" soseki
```

The app runs offline on the simulator (DEBUG plays the captured fixtures); the
live ElevenLabs path goes through the Worker and needs a subscribed `X-User-ID`.

## End-to-end testing

A full pass over the app: the headless pipeline tests, a deterministic
build/install, and a manual checklist that exercises every screen. Most steps use
the **DEBUG launch hooks** so they're reproducible without tapping through the UI.

### 0. Setup (one-time)

```bash
# 1. Headless pipeline — fast, no simulator. Run after ANY ReaderCore change.
cd ReaderCore && swift test            # 41 pass (first run compiles MeCab ~1 min)
cd ..

# 2. Compact tap-to-define DB (gitignored output; skip → app falls back to a mock dict)
scripts/build-compact-dict.sh          # ../jisho-data seed → app/Reader/Resources/jisho-compact.db (~43 MB)

# 3. (Optional, for the live Worker path) copy the env template and fill it in
cp .env.example .env                   # repo root; gitignored. Set READER_WORKER_URL + a subscribed READER_USER_ID

# 4. Signing config (required: xcodegen validates this path). Set your Apple Team ID.
cp app/Signing.xcconfig.example app/Signing.xcconfig   # gitignored; keeps the Team ID out of the public repo

# 5. Build + install on a booted iPhone 17 Pro simulator
cd app && xcodegen generate            # only needed after adding files / editing project.yml
xcodebuild -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
cd ..
DEV=$(xcrun simctl list devices | grep "(Booted)" | grep -oE "[0-9A-F-]{36}" | head -1)
xcrun simctl install "$DEV" app/build/Build/Products/Debug-iphonesimulator/Reader.app
```

The library is **empty by default**; pass `SIMCTL_CHILD_READER_SEED=1` to load the
sample shelf. The committed fixtures (`soseki` / `numbers` / `dialogue`) then make
three of the six samples play **offline** on the sim — no Worker needed for the UI pass.

### 1. Automated — what `swift test` covers

41 tests over the non-UI pipeline (`CharTokenMapper` 8, `MeCab` 4, `SpanTimeline` 4,
`Chunker` 7, `AlignmentStitcher` 4, `JapaneseTextDecoder` 6, `AlignmentFixture` 1,
`ReadingProgressResolver` 7).
The fixture proxy asserts the spike's headless thresholds on real ElevenLabs
alignment: **char-match coverage > 90 %** (the 3 fixtures sit at 100 %), token
starts **monotonic non-decreasing**, and **no NaN** spans (`end ≥ start`). If
coverage drops: confirm both sides NFKC-normalize identically, that `alignment`
(not `normalized_alignment`) is read, that ElevenLabs didn't rewrite the text, then
widen `CharTokenMapper.Options.lookahead` (default 8).

### 2. DEBUG launch hooks (deterministic states)

Pass any of these to a sim launch by prefixing `SIMCTL_CHILD_` (simctl strips it and
injects the rest into the app's env). All are `#if DEBUG` only.

| Hook | Values | Effect |
|---|---|---|
| `READER_SEED` | `1` | load the sample shelf (the library is **empty by default**) |
| `READER_RESET` | `1` | wipe the persisted shelf + narration cache on launch |
| `READER_OPEN` | int index | open library doc N straight into the reader (needs `READER_SEED=1` or an import) |
| `READER_THEME` | `paper`·`sepia`·`night` | start in that theme |
| `READER_ORI` | `tate`·`yoko` | vertical / horizontal text |
| `READER_SEEK` | seconds | move playhead + render highlight, **paused** |
| `READER_AUTOPLAY` | `1` | start playback once loaded |
| `READER_SHEET` | int token index | open the tap-to-define sheet for that token |
| `READER_CHAPTERS` | `1` | open the 目 chapter-nav sheet |
| `READER_IMPORT` | host file path | import an epub/pdf/txt and open it |
| `READER_FORCE_WORKER` | `1` | skip the fixture fallback → hit the live Worker |
| `READER_USER_ID` | id | test `X-User-ID` (subscription gate) |
| `READER_WORKER_URL` | url | override the Worker base URL (from `.env`) |

```bash
# Example: seed the samples, tategaki, paper theme, highlight paused ~1.7 s into 吾輩は猫である
SIMCTL_CHILD_READER_SEED=1 SIMCTL_CHILD_READER_OPEN=0 SIMCTL_CHILD_READER_THEME=paper \
SIMCTL_CHILD_READER_ORI=tate SIMCTL_CHILD_READER_SEEK=1.7 \
  xcrun simctl launch "$DEV" app.reader.app
# Screenshot the current state:
xcrun simctl io "$DEV" screenshot /tmp/yomi.png
```

### 3. Manual checklist (offline, fixtures)

Launch with `xcrun simctl launch "$DEV" app.reader.app` (+ hooks). Each row notes the
fastest way to reach the state and what "pass" looks like.

**Library**
- [ ] Default launch (no hooks) → **empty shelf** with the "Your library is empty / Tap + …" hint.
- [ ] With `SIMCTL_CHILD_READER_SEED=1`: six sample texts list with author + a progress bar; `soseki` (42 %), `銀河鉄道の夜` (88 %), `走れメロス` (読了/Done), two `練習` samples.
- [ ] The three fixture-backed rows (`soseki`, `数字と日付`, `会話文`) show the `↓` cached marker; status reads 未読/`N%`/読了.
- [ ] Cycle the theme toggle (紙/茶/夜) → whole palette swaps instantly.

**Import** (`+` button, or `SIMCTL_CHILD_READER_IMPORT=/path/book.epub`)
- [ ] EPUB → chapters appear in **spine** order (`linear="no"` items skipped); multi-chapter docs get the 目 button.
- [ ] PDF → one chapter per page; `.txt` (UTF-8 / Shift-JIS / EUC sniffed) → one chapter. Unsupported/empty/garbled file → "Import failed" alert.

**Reader** (`READER_SEED=1 READER_OPEN=0`)
- [ ] Text renders with furigana over kanji; `READER_ORI=tate` columns run right-to-left, `yoko` is horizontal.
- [ ] All three themes (`READER_THEME=…`) are legible in the reader **and** the sheets.

**Word-synced highlight** (`READER_SEED=1 READER_OPEN=0 READER_AUTOPLAY=1`) — the core feature
- [ ] Highlight lands on the **correct token** and tracks the audio (target: >95 % correct, <150 ms perceived lag — watch + listen).
- [ ] `READER_SEEK=<sec>` renders a stable paused highlight at that time; scrub by dragging the bar → highlight + audio jump together.

**Tap-to-define** (tap a kanji word, or `READER_SHEET=2` → 猫)
- [ ] A **native** bottom sheet (grabber, swipe-to-dismiss, medium/large detents) shows reading, headword, POS, numbered senses, an example, Save. `猫` returns the full 6-sense jisho entry, not a mock.
- [ ] Tapping punctuation does nothing; an unknown word shows "Not in dictionary".

**Transport**
- [ ] Play/pause toggles the icon and audio; speed pill (0.75× / 1.0× / 1.25×) changes rate; tap empty text area hides/shows the chrome.

**Chapters** (multi-chapter import, then 目, or `READER_CHAPTERS=1`)
- [ ] Native sheet lists chapters; current one is accent-colored with a ▶ marker; tapping another switches and reloads.

**Progress + caching**
- [ ] Play a bit, go back, reopen → resumes at the saved spot; the library row's `N%` updates. Finish a chapter → 読了.
- [ ] Re-opening a previously-synthesized chapter plays from disk (`Caches/Narration/<key>.mp3` + `.json`) with no network.

**Accessibility** (enable VoiceOver, or use Xcode ▸ Open Developer Tool ▸ Accessibility Inspector on the sim)
- [ ] Every icon control speaks a real label (Back, Play/Pause, Theme, Import, Chapters, orientation); the reading area reads as one text block; double-tapping it does **not** fire a random definition.
- [ ] The scrubber is an adjustable slider; speed + current chapter announce "selected"; dismissing the chrome removes it from the VoiceOver order.

**i18n** (force Japanese chrome with a launch arg)
```bash
xcrun simctl launch "$DEV" app.reader.app -AppleLanguages "(ja)" -AppleLocale ja_JP
```
- [ ] Chrome localizes (Yomi↔読み, Unread↔未読, Done↔読了); the **Japanese reading content, furigana, and dictionary headwords stay Japanese** in both languages.

### 4. Live Worker path (the keystone — needs a subscribed user)

Everything above runs on fixtures. The real ElevenLabs round-trip has only been
**auth-smoke-verified** (`401` with no header, `403` for a non-subscriber); a real
synthesis needs a genuinely subscribed `X-User-ID`.

```bash
set -a; . ./.env; set +a               # ELEVEN_KEY, READER_WORKER_URL, READER_USER_ID (repo root)
# NOTE: READER_USER_ID must be SINGLE-QUOTED in .env (it contains `$RCAnonymousID:`),
# else sourcing expands the prefix away and the Worker 403s on the wrong id.
SIMCTL_CHILD_READER_FORCE_WORKER=1 \
SIMCTL_CHILD_READER_WORKER_URL="$READER_WORKER_URL" \
SIMCTL_CHILD_READER_USER_ID="$READER_USER_ID" \
SIMCTL_CHILD_READER_SEED=1 SIMCTL_CHILD_READER_OPEN=0 SIMCTL_CHILD_READER_AUTOPLAY=1 \
  xcrun simctl launch "$DEV" app.reader.app
```
- [ ] Reader reaches `ready` and plays **real** audio with the synced highlight (validates `WorkerTTSService` → real `alignment` decode → `CharTokenMapper` on live data → playback → disk cache).
- [ ] Re-launch the same chapter offline → plays from the cache written on the first run.
- [ ] Import a **long** chapter (> 9 000 chars) → `ChunkingTTSService` splits, synthesizes with 429 backoff, and `AlignmentStitcher` re-stitches into one continuous, **monotonic** highlight across the seam.

A non-subscriber shows "Couldn't load this chapter / Subscription required" (the
`403` path); a missing `X-User-ID` shows "TTS failed (401)".

### 5. Known gaps (require building, not just testing)

- **Subscribed `X-User-ID`** — RevenueCat isn't wired into the app yet, so producing one is external (grant a promotional entitlement to a test appUserID). This single blocker gates the live synth, the chunk→stitch perceptual check, and the on-device listen test.
- **On-device run** — background audio with the screen locked, audio-session interruptions, and Files/share-sheet import are only sim/visually verified.
- **Release Worker URL** — `WorkerBaseURL` (Info.plist via a gitignored xcconfig) isn't wired, so a release/device build hits the placeholder until it is.

## Layout

```
reader/
├── ReaderCore/         # SwiftPM: mapper, tokenizer, SpanTimeline, ContentKey,
│                       #   models + service protocols (TTS/Dictionary/stores). swift test-able.
├── app/
│   └── Reader/         # the product app (Yomi): App/Theme/L10n + Library/ Reader/ Services/
├── docs/               # char-token-sync.md, design-prompt.md
└── scripts/            # capture-alignment.mjs
```
