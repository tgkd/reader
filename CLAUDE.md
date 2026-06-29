# CLAUDE.md — `reader` (Japanese reader with synced audio)

Guidance for Claude Code. A standalone iOS app (working name **Yomi**, target `Reader`,
bundle `app.reader.app`) that plays TTS audio with **word-synced highlighting**, furigana,
and tap-to-define. NOT the Jisho dictionary.

Siblings under `~/Projects/j/` (`ios-native`, `jisho`, `jisho-data`) are **pattern
references only** — crib from them, don't depend on or modify them. The TTS proxy Worker
lives at `~/Projects/cloudflare/aiwork`; the tap-to-define DB is built from `../jisho-data`.
`docs/char-token-sync.md` is the deep dive on the one hard algorithm.

## Thesis

TTS returns **per-character** timings; Japanese has **no spaces**, so word boundaries come
from a tokenizer and the char timings are folded onto token spans (`CharTokenMapper`). **One
MeCab pass per chapter is the single source of truth** for (a) highlight sync spans, (b)
furigana readings, (c) `dictionaryForm` (kanji lemma) for lookup. Never add a second
segmenter — it will disagree with the furigana segmentation.

## Invariants & key decisions (don't break / don't relitigate without cause)

- **`CharTokenMapper` is load-bearing** — two-pointer + monotonic clamp, not naive positional
  slicing (which breaks on whitespace collapse, punctuation, dropped/inserted chars, surrogate
  pairs). See `docs/char-token-sync.md`. Keep `CharTokenMapperTests` + `AlignmentFixtureTests` green.
- **Read `alignment`, never `normalized_alignment`** — ElevenLabs text normalization can rewrite
  numbers/dates; only `alignment` tracks the displayed/tokenized text.
- **Normalize once (NFKC), identically everywhere** — tokenizer + TTS + `ContentKey`. New
  ingestion paths normalize at the boundary, never at import.
- **`Chunker` lossless, `AlignmentStitcher` monotonic** — `Chunker.split(text).joined()` must
  equal the input exactly; the stitcher offsets each segment so token starts stay non-decreasing.
- **`RubyTextView` is custom CoreText** — UILabel/UITextView give no per-token geometry and no
  vertical text. Ruby via `CTRubyAnnotation`, tategaki via frame progression; the CTFrame is
  cached (rebuilt on structure change, not per highlight frame).
- **MeCab-Swift + IPADic**, tokenized with `.katakana` (keeps the kanji lemma; we hiragana-ize the
  reading ourselves). ~50 MB, lazy-loaded off the launch path.
- **`ReaderCore` stays UI-free + `swift test`-able on macOS** — contracts + logic here;
  SwiftUI / CoreText / AVFoundation / Vision / PDFKit / networking in the app target only.
- **Theme via the SwiftUI Environment, not props** — three themes (paper / sepia / night).
- **i18n: chrome localizes (system locale), reader content stays Japanese** — add UI strings to
  `L10n` + both `.lproj`; never localize reader content.
- **Subscription gates ONLY speech generation + enhanced OCR** — reading (text, furigana,
  tap-to-define, import, themes, settings) is free. Synthesis is lazy (first Play). Local
  `isSubscribed()` (RevenueCat `reader Pro`) decides the UI; the Worker's 403 is the backstop.
- **Fixtures are the golden record + DEBUG offline fallback** — commit `fixtures/*.json`
  (`*.mp3` gitignored); release uses the Worker only.

## Architecture at a glance

- **TTS:** ElevenLabs `with-timestamps` via the aiwork Worker `POST /tts/aligned` (gated by
  `revenueCatAuth`, needs a subscribed `X-User-ID`). `WorkerTTSService` → `ChunkingTTSService`
  (splits >9k-char chapters with 429 backoff, then stitches). `DiskAudioStore` content-addresses
  `<key>.mp3` + `<key>.json` by `ContentKey = sha256(nfkc(text)+voice+model)`, so re-reads play offline.
- **Reader:** `ReaderModel` (`AVAudioPlayer` + `CADisplayLink`; highlight via `SpanTimeline.index(at:)`)
  renders `RubyTextView`. `LoadState` (surface) is split from `AudioState` (gate/synth).
- **Dictionary:** `SQLiteDictionaryService` over a compact ~43 MB jisho DB (`build-compact-dict.sh`,
  gitignored), keyed on `dictionaryForm`; falls back to a mock if the DB is absent.
- **Import:** `Importer` routes by extension → `EPUBImporter` (ZIPFoundation, OPF **spine** order) /
  `PDFImporter` / `TextImporter` (encoding sniff). One `Chapter` per spine item / PDF page;
  multi-chapter docs get a chapter-nav sheet.
- **PDF OCR:** `PDFImporter` OCRs pages with no text layer via a `PDFTextRecognizer` (batch of
  `CGImage`, bounded-memory windows). Default = on-device `VisionOCRService` (+ `ReadingOrder` for
  column reconstruction); subscribers can opt into the Worker `POST /pdf/ocr` enhanced path
  (`WorkerOCRService`, `FallbackOCRService` degrades to Vision on any error). No LLM text-rewrite
  (fidelity: furigana/TTS must read the author's text).
- **Settings / persistence:** reading font + size + enhanced-OCR toggle. Theme + font + size persist
  via `UserDefaults`. Chrome controls are SF Symbols (language-neutral).

## Layout

```
reader/
├── ReaderCore/                      # SwiftPM (1 dep: MeCab-Swift) — non-UI logic + contracts; swift test-able on macOS
│   └── Sources/ReaderCore/          #   CharTokenMapper, Chunker, AlignmentStitcher, SpanTimeline,
│                                    #   MeCabTokenizer, Normalize, ContentKey, JapaneseTextDecoder,
│                                    #   models (Document/Chapter/...) + protocols (TTS/Dictionary/stores/DocumentImporter)
├── app/                             # xcodegen — edit project.yml, not the .xcodeproj (gitignored)
│   ├── Reader/                      #   the product app (Yomi)
│   │   ├── App/Theme/L10n + RootView/Components
│   │   ├── Library/  Reader/  Settings/
│   │   └── Services/                #   TTS stack, DiskAudioStore/DiskLibraryStore, dictionary,
│   │                                #   importers (EPUB/PDF/Text), PDF OCR (Vision + Worker engines)
│   └── ReaderTests/                 #   app-target tests (importers + OCR), runtime-generated fixtures
├── docs/                            # char-token-sync.md, design-prompt.md
└── scripts/                         # capture-alignment.mjs, build-compact-dict.sh
```

## Commands

```bash
# Non-UI pipeline + contracts — fast, no simulator. Run after ANY ReaderCore change. (42 tests)
cd ReaderCore && swift test

# App-target tests (importers + OCR) — needs the simulator. (41 tests)
cd app && xcodebuild test -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build

# Build/run the app:
scripts/build-compact-dict.sh                          # build the tap-to-define DB once (gitignored output)
cp app/Signing.xcconfig.example app/Signing.xcconfig   # once: set your Team ID (gitignored; xcodegen requires it)
cd app && xcodegen generate                            # after adding files / editing project.yml
xcodebuild -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build

# Production TTS Worker (USER runs — mutates the live Worker):
cd ~/Projects/cloudflare/aiwork && npx wrangler deploy
```

First `swift test` compiles MeCab (~1 min) and downloads IPADic (~50 MB); later runs are instant.

**DEBUG launch hooks** (`#if DEBUG`; pass via `SIMCTL_CHILD_<VAR>` to a sim launch, or as Xcode
scheme env vars on device). The library is **empty by default**:
- Library/reader: `READER_SEED=1`, `READER_RESET=1`, `READER_OPEN=<index>`, `READER_THEME`,
  `READER_FONT`, `READER_SIZE`, `READER_ORI=tate|yoko`, `READER_SEEK=<sec>`, `READER_AUTOPLAY=1`,
  `READER_SHEET=<token>`, `READER_CHAPTERS=1`, `READER_SETTINGS=1`.
- Import / OCR: `READER_IMPORT=<host path>` (epub/pdf/txt; scanned PDFs use on-device Vision OCR),
  `READER_ENHANCED_OCR=1` (opt into the Worker OCR path).
- Worker / subscription: `READER_FORCE_WORKER=1`, `READER_WORKER_URL=<url>`, `READER_USER_ID=<id>`,
  `READER_RC_KEY` / `READER_RC_USER`, `READER_PAYWALL=1`. (`.env` is gitignored; see `.env.example`.)

## Status

The sync pipeline, product app (Library / Reader / Dictionary, 3 themes, tategaki + yokogaki with
furigana + synced highlight), caching, reading-progress writeback, import (EPUB / PDF / TXT +
scanned-PDF OCR), the audio-only subscription gate, and Settings are all **built and sim-verified**.

**Standing gap:** the live Worker synthesis paths (`/tts/aligned`, `/pdf/ocr`) are deployed and
auth-gated (401/403 smoke-verified) but a real synth needs a genuinely subscribed `X-User-ID`. The
app's RevenueCat SDK + paywall + gate are wired and sim-verified; what's pending is the **App
Store↔RevenueCat binding** — a real `appl_` SDK key (the sim ships a `test_` key, which is skipped
on device, so device builds don't configure RevenueCat). See `docs/testflight.md`: create the App
Store app in RevenueCat (via an In-App Purchase `.p8`), attach `app.reader.app.monthly` to `reader
Pro` + the offering, set `REVENUECAT_KEY = appl_…` in `Signing.xcconfig`. On the sim you can shortcut
the gate with `READER_FORCE_WORKER=1` + `READER_USER_ID=<subscribed id>`. (The paywall is guarded so a
build without a real key shows a fallback instead of crashing.)

**Open follow-ups (low):** prune per-segment cache entries after a successful stitch; memoize
`LibraryModel.load`'s `ContentKey` hashing; reading-override table for homograph furigana; optional
in-app language toggle / AVAudioEngine if drift appears / batch pre-gen for offline.
