# reader — Japanese reader with synced audio (iOS)

Read Japanese text with word-synced TTS highlighting, furigana, and tap-to-define.
Standalone app (working name **Yomi**); the sibling Jisho apps are referenced for
code patterns only, not reused as a base.

**Docs:** [`CLAUDE.md`](CLAUDE.md) — working state, decisions, invariants, commands,
and DEBUG hooks. [`docs/char-token-sync.md`](docs/char-token-sync.md) — the
char→token mapping algorithm (read before touching `CharTokenMapper`).

## The hard part

TTS gives **per-character** timings; Japanese has no spaces, so word boundaries must
come from a tokenizer and the character timings folded onto token spans. That
char→token mapping was the only genuinely hard risk, so it was de-risked first. One
MeCab pass is the single source of truth for **sync spans + furigana readings +
dictionary lemmas** — never a second segmenter.

Stack: ElevenLabs `with-timestamps` (via the `aiwork` Cloudflare Worker) ·
MeCab+IPADic · custom CoreText reader (ruby + vertical/horizontal + synced
highlight) · content-addressed disk cache · jisho→SQLite tap-to-define · Vision /
Worker OCR for scanned PDFs.

## Status

The sync pipeline, product app (Library / Reader / Dictionary, 3 themes, tategaki +
yokogaki, tap-to-define), caching, reading-progress, import (EPUB / PDF / TXT +
scanned-PDF OCR), and the audio-only subscription gate are all built and
sim-verified. The one standing gap: the live Worker synthesis paths (`/tts/aligned`,
`/pdf/ocr`) are deployed and auth-gated, but a real synth needs a subscribed
`X-User-ID`. The RevenueCat SDK + paywall + gate are wired; what's pending is the
App Store↔RevenueCat binding (a real `appl_` key) so device builds can purchase —
see [`docs/testflight.md`](docs/testflight.md).

`ReaderCore/` is a dependency-light SwiftPM package (MeCab-Swift only) holding all
non-UI logic and the service contracts; it builds for macOS, so the mapper +
tokenizer + fixture pipeline are verifiable with `swift test`. The app target
(`Reader`) is for the visual/perceptual checks.

## Run

```bash
cd ReaderCore && swift test            # non-UI pipeline — run after any ReaderCore change

scripts/build-compact-dict.sh          # build the tap-to-define DB once (gitignored output)

cp app/Signing.xcconfig.example app/Signing.xcconfig   # set your Team ID (gitignored; required before xcodegen)
cd app && xcodegen generate
xcodebuild -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
```

The library is **empty by default**; `SIMCTL_CHILD_READER_SEED=1` loads the sample
shelf (three samples play offline from committed fixtures). DEBUG launch hooks
(`READER_*`, passed via `SIMCTL_CHILD_`) give deterministic states for screenshots
and testing — see [`CLAUDE.md`](CLAUDE.md) for the full list. The live ElevenLabs
path goes through the Worker and needs a subscribed `X-User-ID`.

## Layout

```
reader/
├── ReaderCore/   # SwiftPM: mapper, tokenizer, SpanTimeline, models + service contracts. swift test-able.
├── app/Reader/   # the product app (Yomi): App/Theme/L10n + Library/ Reader/ Settings/ Services/
├── docs/         # char-token-sync.md, design-prompt.md
└── scripts/      # capture-alignment.mjs, build-compact-dict.sh
```
