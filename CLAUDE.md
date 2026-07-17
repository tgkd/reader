# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**Yomi** — a standalone iOS app (target `Reader`, bundle `app.reader.app`, display name *Yomi*)
that reads Japanese books aloud with **word-synced highlighting**, furigana, and tap-to-define.
It is NOT a dictionary app. Sibling projects under `~/Projects/j/` are pattern references only —
don't depend on or modify them. The TTS/OCR proxy Worker lives at `~/Projects/cloudflare/aiwork`;
the tap-to-define DB is built from `../jisho-data`.

## The one hard idea

TTS returns **per-character** timings, but Japanese has no spaces, so word boundaries come from a
tokenizer. The char timings are folded onto token spans by `CharTokenMapper` (two-pointer +
monotonic clamp, NOT naive positional slicing — that breaks on whitespace collapse, punctuation,
and surrogate pairs). See `docs/char-token-sync.md`.

**One MeCab pass per chapter is the single source of truth** for (a) highlight sync spans,
(b) furigana readings, (c) `dictionaryForm` (kanji lemma) for lookup. Never add a second
segmenter — it will disagree with the furigana segmentation. `MeCabTokenizer` also emits the
whitespace it would otherwise drop as untimed gap tokens (walking `annotation.range`), so
`joined(surfaces) == nfkc(text)` holds and paragraphs / line breaks / indents survive to the page.

## Architecture

Two modules. The split is load-bearing: **all non-UI logic + contracts live in `ReaderCore`,
which is headless and `swift test`-able on macOS** (no simulator). SwiftUI / CoreText / AVFoundation /
PDFKit / networking live in the `app/` target only.

- **`ReaderCore/`** (SwiftPM, one dep: MeCab-Swift + IPADic) — `CharTokenMapper`, `Chunker`,
  `AlignmentStitcher`, `SpanTimeline`, `MeCabTokenizer`, `Normalize`, `ContentKey`,
  `ReadingProgressResolver`, `JapaneseTextDecoder`; the model types (`Document`/`Chapter`/
  `ReadingProgress`/`Token`/`TokenSpan`/`Alignment`) and the protocols (`TTSService`,
  `DictionaryService`, `LibraryStore`, `GeneratedAudioStore`, `DocumentImporter`,
  `JapaneseTokenizer`). Swapping an implementation = changing `AppServices`, nothing else.

- **`app/Reader/`** (xcodegen) — the product app, wired together in **`AppServices`** (the one
  place implementations are chosen) and **`AppModel`** (top-level `@Observable`: theme, route,
  persisted reading prefs, paywall). `RootView` routes Library ↔ Reader (a simple enum, not a
  NavigationStack — the reader is a full-screen takeover).

### Pipelines

- **TTS:** `WorkerTTSService` (POSTs `/tts/aligned` on the aiwork Worker → ElevenLabs
  `with-timestamps`, behind a RevenueCat gate; client sends only `X-User-ID`; 300 s request
  timeout — the route buffers the whole response, so a long chunk yields no bytes until done) →
  wrapped by `ChunkingTTSService` (splits chapters over `Chunker.defaultMaxChars` ≈ 9k chars,
  bounded concurrency ~2, exponential 429 backoff on **both** the chunked and single-request paths;
  saves the whole chapter durably **before** pruning per-segment entries; then `AlignmentStitcher`
  stitches) → cached by `DiskAudioStore`, content-addressed by
  `ContentKey = sha256(model + voice + nfkc(text))`, so re-reads play offline for free.
  `FixtureTTSService` provides DEBUG offline fixtures and the library's "is this cached?" probe.

- **Reader:** `ReaderModel` drives one chapter — `AVAudioPlayer` + a `CADisplayLink` proxy advance
  `activeIndex` each frame via `SpanTimeline.index(at:)`; an `AVAudioPlayerDelegate` +
  `AVAudioSession` interruption observer own completion / pause-resume so they still fire while
  backgrounded (the display link is a foreground-only clock). `NowPlayingController` (lifecycle
  mirrors the audio session exactly) publishes lock-screen/Control Center metadata + remote
  commands — playback state is written at transitions only (play/pause/seek/speed/chapter),
  never per tick; the system extrapolates. `.synthesizing` shows `synthesisProgress`, a purely
  cosmetic 10 Hz eased estimate (the Worker buffers the whole response, so no real signal
  exists) that creeps toward ~0.92 and snaps to 1 on success. `RubyTextView` (custom CoreText)
  renders furigana via `CTRubyAnnotation` and vertical text via frame progression: the base text is
  drawn once with an **explicit per-run ink color** (NOT `kCTForegroundColorFromContext` — the first
  ruby annotation clobbers the context fill, invisibly in paper but black-on-black in night), and
  the moving highlight is a separate `CAShapeLayer` fill so advancing it never repaints the chapter.
  During playback a display-link follow eases `contentOffset` directly (never
  `setContentOffset(animated:)`) to keep the active LINE at screen center, clamped at chapter
  ends; it yields to manual drags, honors Reduce Motion, and stops itself when settled.
  **`LoadState` (the always-available reading surface) is split from `AudioState`** (the gated synth
  lifecycle: `.locked`/`.idle`/`.synthesizing`/`.ready`/`.notGenerated`/`.failed`). Progress
  writeback goes through `ReadingProgressResolver` (tested), never per frame; free (no-audio)
  reading persists at least the chapter position.

- **Chrome (iOS 26 Liquid Glass):** no bars — the reader header is floating glass (circle back
  button, title capsule with chapter subtitle that IS the chapter selector, toggle cluster) and
  the player is one full-width glass pill in every audio state (native `Slider` scrubber, speed
  `Menu`, determinate synthesis bar). Chrome clearance lives INSIDE `RubyScrollView` — a vertical
  `contentInset` in yokogaki (text scrolls under the glass, giving it something to blur) but the
  column band in tategaki (whose full-height columns would otherwise sit permanently under the
  pills). The pill deliberately has NO chapter arrows (they read as time-skips in an audiobook
  context); chapter moves = title capsule → chapters sheet, or lock-screen prev/next. Native
  controls tint from the theme accent via a root-level `.tint` in `RootView`.

- **Dictionary:** `SQLiteDictionaryService` over a compact ~bundled jisho DB
  (`scripts/build-compact-dict.sh`, gitignored output), keyed on `dictionaryForm`; falls back to
  `MockDictionaryService.seeded()` if the DB resource is absent. Tap-to-define's *pronounce*
  button uses `AVSpeechSynthesizer` (on-device, free, ungated) — distinct from chapter narration.

- **Import:** orchestrated by **`AppModel`** (not the view — so a slow import survives a Library↔Reader
  route switch; reachable from the `+` picker AND `RootView.onOpenURL` / `CFBundleDocumentTypes`, i.e.
  "Open in Yomi" from Files / Mail / the share sheet). `Importer` routes by extension → `EPUBImporter`
  (ZIPFoundation; reading order from the OPF **`<spine>`**, never the manifest; strips `<rt>/<rp>` ruby
  so furigana isn't inlined; chapter titles from the TOC — EPUB3 nav document preferred, regex-parsed
  like body XHTML, EPUB2 NCX fallback via strict `XMLParser` — hrefs resolved relative to the TOC
  document's own directory, fragments stripped, first entry per file wins, any failure degrades to
  untitled) / `PDFImporter` / `TextImporter` (scored encoding sniff via `JapaneseTextDecoder`).
  One `Chapter` per spine item / PDF page, then any oversized chapter is split into
  ≤ `Chapter.maxRenderableChars` (~4k) sub-chapters (see the invariant below).

- **OCR (cloud-only, subscriber-gated):** pages/spine items with no text layer are OCR'd via
  `WorkerOCRService` → Worker `/pdf/ocr` → Cloudflare AI Gateway → Gemini. Both `PDFImporter`
  (scanned pages) and `EPUBImporter` (image-only/fixed-layout spine items) use it, in
  bounded-memory windows. `Importer.ocrPageCount` drives a "read N pages with AI?" confirm.
  A non-subscriber's scanned import yields no recognizer → `ImportError.ocrUnavailable`
  (a Membership prompt). On-device Vision OCR was removed (quality too low).

## Invariants (don't break without cause)

- **`CharTokenMapper` is load-bearing.** Keep `CharTokenMapperTests` + `AlignmentFixtureTests` green.
- **Read `alignment`, never `normalized_alignment`** from the TTS response — only `alignment`
  tracks the displayed/tokenized text.
- **Normalize once (NFKC), identically everywhere** (`Normalize.nfkc`): tokenizer, TTS request,
  and `ContentKey` all normalize at their boundary. Import does NOT normalize — it happens
  downstream so every ingestion path shares one normalization.
- **`Chunker.split(text).joined()` must equal the input exactly** (lossless); `AlignmentStitcher`
  keeps token starts monotonic across stitched segments.
- **One CoreText surface per chapter, so chapters are capped at `Chapter.maxRenderableChars` (~4k).**
  A larger chapter exceeds the platform's max layer/texture size and renders BLANK (and tokenizing +
  laying it out janks the main thread). Import splits oversized chapters into sub-chapters at
  paragraph boundaries (reusing `Chunker`); measured on-simulator — do not raise the cap without
  re-measuring across font sizes.
- **Reader text carries an explicit per-run color; the highlight is a separate `CAShapeLayer`.**
  Don't reintroduce `kCTForegroundColorFromContext` for the base runs — a ruby annotation corrupts
  the context fill, which reads fine in paper/sepia but renders black-on-black in the night theme.
- **Subscription gates speech generation AND scanned/image OCR only.** Reading extracted text
  (EPUB / TXT / born-digital PDF) with furigana, tap-to-define, themes, and settings is free.
  `isSubscribed()` (RevenueCat `reader Pro` entitlement) is checked **locally** so the paid Worker
  is never hit for a non-subscriber; the Worker's 403 is the backstop. Synthesis is lazy (first Play).
  That extends to the lock screen: a remote prev/next-chapter skip resumes only cached audio —
  it must NEVER trigger a paid synthesis (see `ReaderModel.remoteOpenChapter`). The narration
  voice picker (Settings) is subscriber-only and hidden otherwise.
- **Every `SynthesisRequest` must carry the selected narration voice** (`services.narrationVoice`,
  mirrored from `AppModel`) — the voice is part of `ContentKey`, so a defaulted request silently
  misses the cache and re-bills synthesis. Current sites: `ReaderModel` (eager probe + synth),
  `AppServices.firstChapterKey` (library ↓ badge; memoized, invalidated on voice change),
  `purgeAudio` (sweeps ALL `Voice.catalog` voices), `VoiceDemoPlayer`.
- **Theme via the SwiftUI Environment, not props** — four themes (paper / white / sepia / night).
  Native controls pick up the theme accent from the root-level `.tint` in `RootView` (never
  system blue).
- **i18n: chrome localizes (en/ja, system locale), reader content stays Japanese.** Add UI strings
  to `L10n` + both `.lproj`; never localize reader content.
- **Fixtures are the golden record:** commit `ReaderCore/Tests/.../fixtures/*.json`; `*.mp3` is
  gitignored and regenerable.

## Commands

```bash
# ReaderCore — fast, no simulator. Run after ANY ReaderCore change.
cd ReaderCore && swift test
swift test --filter CharTokenMapperTests          # a single test class

# App-target tests (importers + OCR) — needs a simulator.
cd app && xcodebuild test -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build
#   single class: add  -only-testing:ReaderTests/EPUBImporterTests

# First-time / after editing project structure:
scripts/build-compact-dict.sh                        # build the tap-to-define DB (gitignored output)
cp app/Signing.xcconfig.example app/Signing.xcconfig # once: set DEVELOPMENT_TEAM (gitignored; xcodegen needs it)
cd app && xcodegen generate                          # regenerate the .xcodeproj after adding files / editing project.yml

# Build/run:
cd app && xcodebuild -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
```

First `swift test` compiles MeCab (~1 min) and downloads IPADic (~50 MB); later runs are instant.

Rendering / themes / the word-synced highlight / live TTS can only be checked on a running app, not
in unit tests. `scripts/uitest/smoke.sh` drives those on a booted simulator via idb and drops
screenshots — see `scripts/uitest/README.md` (incl. the Xcode-26+/27 SimulatorKit setup note).

## Project mechanics

- **The Xcode project is generated — edit `app/project.yml`, never the `.xcodeproj`** (gitignored).
  Run `xcodegen generate` after adding/removing files. App deps: ZIPFoundation (pinned to the
  **0.9.x** line for its failable `Archive(url:accessMode:)` API), RevenueCat.
- **Deployment target is iOS 26.0** — the chrome is built on Liquid Glass (`.glassEffect`,
  `.buttonStyle(.glass)`); lowering the target means re-introducing availability fallbacks for
  every glass surface.
- **No DEBUG launch-env (`READER_*`) overrides exist anymore.** App config comes from the gitignored
  `app/Signing.xcconfig` (`WORKER_HOST`, `REVENUECAT_KEY`, `DEVELOPMENT_TEAM`) → `Info.plist`
  (`WorkerBaseURL`, `RevenueCatKey`). An empty `WORKER_HOST` falls back to the production Worker
  (`api.thetango.org` — not a secret: it ships in every IPA, and all billable routes are
  auth-gated); an empty `REVENUECAT_KEY` leaves the paywall unconfigured (crash-guarded).
  `.env` is read ONLY by `scripts/capture-alignment.mjs` (`ELEVEN_KEY`).
- **Library starts empty** — users import their own books. Swipe-to-delete a row also purges its
  cached narration (`AppServices.purgeAudio`). Settings has a "clear audio cache" control
  (`audioStore.clear()` / `totalBytes()`). Reading font/size/orientation/furigana + theme + the
  narration voice (by `Voice.catalog` id, falling back to George) persist via `UserDefaults` in
  `AppModel`. Voice samples in Settings synthesize one fixed sentence per voice through the normal
  gated TTS path and cache content-addressed — first listen bills, replays are free.
- **Local purchase testing:** `Reader.storekit` is wired into the scheme (run from Xcode, no sandbox
  account needed). The paywall is crash-guarded when RevenueCat is unconfigured. `test_…` RevenueCat
  keys are skipped on physical devices (they crash against real StoreKit). See `docs/testflight.md`.
- **Xcode Cloud:** `app/ci_scripts/ci_post_clone.sh` (+ root `ci_scripts/` delegate) rebuilds what a
  clean checkout lacks: downloads `jisho-compact.db` from the public `compact-dict` GitHub release
  (refresh after regenerating: `gh release upload compact-dict app/Reader/Resources/jisho-compact.db
  --clobber -R tgkd/reader`), writes `Signing.xcconfig` from workflow env vars (`READER_TEAM_ID`,
  `READER_REVENUECAT_KEY`; `READER_WORKER_HOST` is optional — blank uses the production-Worker
  default), runs `xcodegen generate`, and copies the tracked
  `app/Package.resolved` into the generated project (Xcode Cloud disables automatic SPM resolution —
  refresh the copy when pins change). Set the workflow's Xcode version to a release 26.x. No
  `GITHUB_TOKEN` needed — repo and release assets are public.
  **Build numbers are Xcode Cloud-managed**: the workflow's "next build number" was set to 25
  (2026-07-04, above all prior manual TestFlight uploads) and auto-increments per run — don't
  set `CFBundleVersion` for cloud builds.

## Layout

```
reader/
├── ReaderCore/Sources/ReaderCore/   # headless logic + contracts (swift test-able on macOS)
├── ReaderCore/Tests/                #   incl. fixtures/ (committed *.json; *.mp3 gitignored)
├── app/
│   ├── project.yml                  # xcodegen source of truth (edit THIS, not the .xcodeproj)
│   ├── Reader/                      # the product app — App / Theme / L10n / RootView / Components
│   │   ├── Library/  Reader/  Settings/   # Reader/ incl. NowPlayingController; Settings/ incl. VoiceDemoPlayer
│   │   └── Services/                #   AppServices wiring, TTS stack, Disk*Store, dictionary, importers, OCR
│   └── ReaderTests/                 # app-target importer + OCR tests (runtime-generated fixtures)
├── docs/                            # char-token-sync.md (the algorithm), testflight.md, design-prompt.md
└── scripts/                         # build-compact-dict.sh, capture-alignment.mjs
    └── uitest/                      #   idb-driven simulator smoke tests (see its README)
```
