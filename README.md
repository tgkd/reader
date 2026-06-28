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
| Sync pipeline | `CharTokenMapper` + MeCab + real ElevenLabs fixtures | ✅ green — 34 tests, 100% coverage |
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
cd ReaderCore && swift test            # 34 pass — run after any ReaderCore change

# Build the compact tap-to-define DB once (gitignored output), then the app:
scripts/build-compact-dict.sh          # jisho-seed.db → app/Reader/Resources/jisho-compact.db

# Product app (Reader / Yomi)
cd app && xcodegen generate
xcodebuild -project SyncSpike.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
# Deterministic screenshot via DEBUG hooks (e.g. tategaki, highlight at 1.7s):
#   SIMCTL_CHILD_READER_OPEN=0 SIMCTL_CHILD_READER_ORI=tate SIMCTL_CHILD_READER_SEEK=1.7

# Capture ElevenLabs fixtures (your key in reader/.env as ELEVEN_KEY):
node scripts/capture-alignment.mjs "吾輩は猫である。" soseki
```

The app runs offline on the simulator (DEBUG plays the captured fixtures); the
live ElevenLabs path goes through the Worker and needs a subscribed `X-User-ID`.

## Layout

```
reader/
├── ReaderCore/         # SwiftPM: mapper, tokenizer, SpanTimeline, ContentKey,
│                       #   models + service protocols (TTS/Dictionary/stores). swift test-able.
├── app/
│   ├── SyncSpike/      # old throwaway sync-overlay spike (kept)
│   └── Reader/         # the product app (Yomi): App/Theme/L10n + Library/ Reader/ Services/
├── docs/               # char-token-sync.md, design-prompt.md
└── scripts/            # capture-alignment.mjs
```
