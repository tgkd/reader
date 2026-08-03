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
segmenter — it will disagree with the furigana segmentation. All tokenization goes through
the `TokenizerWorker` actor (app target): off the main thread — the one-time ~50 MB IPADic
load and per-chapter tokenize used to freeze the reader-open transition — and serialized,
because MeCab is not thread-safe. Never tokenize on the main actor. `MeCabTokenizer` also emits the
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
  timeout between chunks, 900 s total) — the client sends `stream: true` and the route proxies
  ElevenLabs' NDJSON **unbuffered**. This is not an optimization: on the buffered endpoint
  ElevenLabs emits nothing until the whole chapter is done and its own edge 524s first
  (~200 s of work on v3 against roughly a 100 s ceiling), so a chapter could not be generated
  at all. Chunk timestamps are ABSOLUTE, so the client concatenates rather than stitches, and a
  short reassembly is rejected — a truncated stream is internally consistent and would
  otherwise cache as a complete chapter missing its tail) →
  wrapped by `ChunkingTTSService` (splits chapters over `SynthesisLimits.maxRequestChars` — one
  constant, held under `eleven_v3`'s 5k since the client no longer knows which model the Worker
  picks and the models' limits differ 8x; in practice chapters are capped below it so the chunked
  path never fires,
  bounded concurrency ~2, exponential 429 backoff on **both** the chunked and single-request paths;
  saves the whole chapter durably **before** pruning per-segment entries; then `AlignmentStitcher`
  stitches) → cached by `DiskAudioStore`, content-addressed by
  `ContentKey = sha256(voice + nfkc(text))`, so re-reads play offline for free.
  Chapter synthesis requests are owned by **`SynthesisCoordinator`** (session-scoped, keyed by
  `ContentKey`): leaving the reader does NOT cancel a paid request — the result still lands in
  the cache — and a reopen re-attaches to the same in-flight task instead of re-billing; each
  request holds a background-task assertion (~30 s of grace on an app switch). The synthesizing
  pill's X is the one deliberate cancel.
  `FixtureTTSService` provides DEBUG offline fixtures and the library's "is this cached?" probe.

- **Reader:** `ReaderModel` drives one chapter — **`AVPlayer`** (NOT `AVAudioPlayer`, which needs the
  finished file: narration is played WHILE it is still being generated) fed by `ChapterAudioSource`,
  an `AVAssetResourceLoaderDelegate` serving a growing mp3. Cached chapters take the same path with
  all bytes appended at once, so there is ONE set of transport/completion/interruption behaviours.
  A `CADisplayLink` proxy advances
  `activeIndex` each frame via `SpanTimeline.index(at:)`; `AVPlayerItem`'s didPlayToEnd /
  failedToPlayToEnd notifications +
  `AVAudioSession` interruption/route-change observers own completion / pause-resume so they
  still fire while backgrounded (the display link is a foreground-only clock) — resume after an
  interruption only if the user was playing when it began; pause when the output route
  disappears (headphones out). Natural chapter finish auto-advances into the next chapter
  **only if its audio is already cached** (the lock-screen-skip rule), else the Now Playing
  widget stays (paused at the end) and only the audio session is released — the widget is torn
  down on explicit stop/leave. `NowPlayingController` publishes lock-screen/Control Center
  metadata + remote commands — playback state is written at transitions only
  (play/pause/seek/speed/chapter), never per tick; the system extrapolates.
  **Playback starts after a ~4 s head start and generation continues behind it** — chunks arrive via
  `SynthesisStream` (keyed by `ContentKey`, so a re-entering reader attaches to a generation it did
  not start). Generation runs faster than playback, so it is not caught up with. `.synthesizing`
  is therefore a ~4 s pre-roll, not the whole chapter, and `synthesisProgress` is MEASURED (delivered
  characters / total), not eased. **The two streams are NOT in step: the alignment frontier runs
  1.4–3.1 s AHEAD of the audio it describes** (measured 2026-08-01 on `eleven_v3` — most chunks carry
  audio with no alignment at all, and a few carry alignment for audio still to come). So the two
  clocks are tracked separately and are not interchangeable: `generatedTime` (how much narration
  EXISTS — the head start, the seek limit, the scrubber's buffered band) is bytes appended /
  `mp3BytesPerSecond`, while `Progressive.alignedTime` (`endTimes.last`) is the only clock that may be
  divided by a character count, because only it counts the same characters. Reading `generatedTime`
  off the alignment had the player promising seconds of narration that had not arrived.
  **Chapter length is estimated from a measured rate, and the estimate is never
  rendered as digits.** Measured speech rates ranged 3.6–6.8 chars/s across content, so a constant is
  wrong by up to 2x: both the idle player's "about N min" and the in-flight `duration` come from
  `AppServices.measuredSecondsPerChar`, learned at the seal of any chapter generated with that voice
  and **persisted per voice** (session scope meant every cold launch fell back to the constant, so the
  first chapter was seeded wrong and then jumped). `duration` is re-projected from this chapter's own
  alignment only after `estimateEvidenceSeconds` of audio exists — extrapolating from the 4 s head
  start, typically a title line and a pause, moved it by tens of percent. Even so the player shows
  **NO time readout at all while generating** — remaining (`−m:ss`) appears only once sealed. The
  total is a projection until then, so every readout built on it moves; a countdown that goes up
  reads as a bug, and elapsed-instead (the previous compromise) still redrew every second beside a
  scrubber whose length was shifting. There is no honest number yet, so none is shown — the collapsed
  circle falls back to the generation percentage, which is shown precisely because it only ever moves
  forward: the pre-roll ending (`startProgressivePlayback`) must NOT complete the bar, or the circle
  reads 100% and then drops back to the real figure on the next chunk. The estimate still drives
  the ring, the scrubber and the Now Playing duration, where the same error is a few pixels of arc.
  `RubyTextView` (custom CoreText)
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
  the player (`PlayerView`) is a collapsible 58 pt glass circle bottom-right — thin ring =
  playback position (or generation %, with the percent as its center label; a timer-only center
  while playing), tap only ever expands — that morphs into a full-width glass capsule via the
  system `glassEffectID` morph in a `GlassEffectContainer` (native `Slider` scrubber,
  tap-to-cycle speed pill, determinate synthesis bar + cancel; membership CTA when locked).
  The capsule's state rows swap STRUCTURALLY (`switch`, default opacity transition) — opacity-
  gating mounted siblings leaks phantom accessibility elements through glass-hosted subtrees.
  Chrome clearance lives INSIDE `RubyScrollView` — a vertical
  `contentInset` in yokogaki (text scrolls under the glass, giving it something to blur) but the
  column band in tategaki (whose full-height columns would otherwise sit permanently under the
  pills). The player deliberately has NO chapter arrows (they read as time-skips in an audiobook
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
  untitled) / `PDFImporter` / `TextImporter` (scored encoding sniff via `JapaneseTextDecoder`;
  `.md`/`.markdown` route here too with `MarkdownStrip` — markers dropped, wrapped text kept, so
  syntax isn't furigana'd/narrated). The Library `+` is a menu: file picker OR **paste text**
  (`PasteTextView` → `AppModel.importPastedText` — no file; title defaults to the first line;
  never reads `UIPasteboard` programmatically, avoiding the iOS paste banner).
  One `Chapter` per spine item / PDF page (pasted text = one chapter), then any oversized chapter
  is split into ≤ `Chapter.maxRenderableChars` (~4k) sub-chapters (see the invariant below).

- **OCR (cloud-only, subscriber-gated):** pages/spine items with no text layer are OCR'd via
  `WorkerOCRService` → Worker `/pdf/ocr` → Cloudflare AI Gateway. The app posts only
  `image_base64` — model and prompt are entirely server-side, and have been since before TTS
  followed: the page-image path runs `openai/gpt-5.6-terra` (`OCR_MODEL`), the cheap text-cleanup
  path `google-ai-studio/gemini-2.5-flash` (`OCR_TEXT_MODEL`); see aiwork's `OCR-MODELS.md` for why
  gemini-2.5-flash lost the image path (it emits running headers / page numbers into the text on
  every run). Both `PDFImporter`
  (scanned pages) and `EPUBImporter` (image-only/fixed-layout spine items) use it, in
  bounded-memory windows. `Importer.ocrPageCount` drives a "read N pages with AI?" confirm.
  A non-subscriber's scanned import yields no recognizer → `ImportError.ocrUnavailable`
  (a Membership prompt). On-device Vision OCR was removed (quality too low).

## Invariants (don't break without cause)

- **`CharTokenMapper` is load-bearing.** Keep `CharTokenMapperTests` + `AlignmentFixtureTests` green.
- **`SpanTimeline.index(at:)` must never answer past the last TIMED span.** A chapter is highlighted
  while it is still generating, so the timeline is routinely the WHOLE chapter's tokens folded against
  a PARTIAL alignment — and `CharTokenMapper` interpolates every token past the alignment's end from
  its predecessor, giving that entire trailing run one identical start. Unclamped, the binary search
  therefore returns the LAST TOKEN OF THE CHAPTER the instant the playhead touches the frontier, and
  the highlight (and the auto-scroll following it) is thrown to the end of the text until the next
  rebuild — the "highlight is nowhere near the audio" bug. The timings themselves were never at
  fault: verified 2026-08-01 against the live API (alignment 21.520 s vs 21.551 s of real audio) and
  `AVPlayer`'s clock (zero accumulating drift, even with a wrong advertised `contentLength`). Past
  the frontier the highlight HOLDS; `timelineRefreshSeconds` is how long it may hold, so keep it well
  under `headStartSeconds`.
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
  **Cached narration plays regardless of entitlement** (decision 2026-07-22): `ReaderModel.load()`
  probes the audio cache BEFORE the subscription check, so a lapsed subscriber keeps playing
  chapters they already generated (offline-proof — no RevenueCat lookup on the cached path);
  only a cache miss reaches `isSubscribed()`, and only new synthesis / voice changes /
  regenerating evicted audio require the entitlement.
  `isSubscribed()` (RevenueCat `reader Pro` entitlement) is checked **locally** so the paid Worker
  is never hit for a non-subscriber; the Worker's 403 is the backstop. Synthesis is lazy (first Play).
  That extends to every unattended path: a remote prev/next-chapter skip AND the
  natural-finish auto-advance resume only cached audio — they must NEVER trigger a paid
  synthesis (see `ReaderModel.remoteOpenChapter`). The narration
  voice picker (Settings) is subscriber-only and hidden otherwise.
- **The app decides WHAT to read and in WHICH VOICE; the Worker decides everything else.** The
  request body is exactly `{text, voice_id, stream}`. The model, `language_code` and the five
  `voice_settings` live in aiwork's `src/tts.ts` (model overridable via the `TTS_MODEL` var), so
  narration is re-modelled or retuned **without an App Store release**. `stream` stays client-sent
  because it declares "I can consume NDJSON" — a fact about the client, not config — and the Worker
  defaults it too. The Worker allow-lists `voice_id` against the same six ids as `Voice.catalog`;
  adding a voice needs BOTH. An explicitly-sent `model_id` still wins server-side, for builds
  shipped before the move — don't "clean that up" until those age out.
- **Every `SynthesisRequest` must carry the selected narration voice** (`services.narrationVoice`,
  mirrored from `AppModel`) — the voice is the only thing besides the text in `ContentKey`, so a
  defaulted request silently misses the cache and re-bills synthesis. Current sites: `ReaderModel`
  (eager probe + synth), `AppServices.firstChapterKey` (library ↓ badge; memoized, invalidated on
  voice change), `purgeAudio` (sweeps ALL `Voice.catalog` voices **x** every key a probe can
  resolve, i.e. `cacheKeyCandidates` — anything `loadAllowingLegacyModel` finds must be reclaimable).
- **The model is NOT in `ContentKey`, and audio outlives model changes.** It used to be, back when
  the app chose it; keying on something the client can't see would make its own cache unnameable,
  and every default change silently re-billed users for chapters they'd already paid for. Builds
  that keyed on it wrote `sha256(model + voice + text)`, so probes fall back through
  `LegacyAudioCache.modelIDs` (`eleven_flash_v2_5`, `eleven_v3`, `eleven_multilingual_v2` — the
  closed set of shipped defaults, **which can never grow**). Consequence, accepted deliberately: one
  book can hold audio from two models. Replayed `eleven_v3` audio keeps that model's alignment
  defect (timings that don't describe all of its own audio → highlight leads, then HOLDs at the
  frontier); degraded sync on audio the user owns beats deleting it.
- **Narration is Japanese-native by construction, and the Worker's request says so.** The default
  voice is a native JA library voice (an English voice speaking Japanese inherits its phonology:
  English accent + flattened pitch accent, unrecoverable by any parameter), and the Worker pins
  `language_code: "ja"` — without it the multilingual pipeline resolves kanji through *Chinese*
  (日本橋 romanizes as "Ri Ben Qiao"). `voice_settings` are sent explicitly so a shared-library
  voice's own saved settings don't decide delivery; they are deliberately NOT in `ContentKey`, so
  retuning them does not invalidate paid audio. **Never send
  `apply_language_text_normalization`** — it is an LLM pass that speaks its own reasoning aloud
  ("Wait, let me redo this properly: …"), 4x duration, one char absorbing 15 s of alignment
  (measured 2026-07-29). The Worker builds the upstream body field by field so it cannot reappear;
  `test/tts.test.ts` there and `WorkerTTSServiceTests` here both assert it stays off the wire.
  The default model is `eleven_flash_v2_5`; `eleven_v3` must never be it (see
  `docs/2026-08-03-findings.md`).
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
  narration voice (by `Voice.catalog` id, falling back to Shizuka) persist via `UserDefaults` in
  `AppModel`. Voice samples in Settings synthesize one fixed sentence per voice through the normal
  gated TTS path and cache content-addressed — first listen bills, replays are free.
- **Local purchase testing:** `Reader.storekit` is wired into the scheme (run from Xcode, no sandbox
  account needed). The paywall is crash-guarded when RevenueCat is unconfigured. The RevenueCat key
  is configured verbatim on every platform — NO build-flavor or device branches (a silently skipped
  key once shipped a fake-"active" build that 401'd at the Worker); an unconfigured build reads
  not-subscribed everywhere, and a `test_…` key on a physical device fails loudly in RevenueCat
  instead of being quietly ignored. See `docs/testflight.md`.
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
│                                    #   2026-08-03-findings.md — why narration left eleven_v3, why
│                                    #   OCR left gemini-2.5-flash, and how publisher ruby is read.
│                                    #   Read it BEFORE re-opening any of those; it records what was
│                                    #   measured, what was ruled out, and what is still unexplained.
└── scripts/                         # build-compact-dict.sh, capture-alignment.mjs
    └── uitest/                      #   idb-driven simulator smoke tests (see its README)
```
