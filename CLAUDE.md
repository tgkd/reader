# CLAUDE.md — `reader` (Japanese reader with synced audio)

Guidance for Claude Code working in this directory. **This is a new, standalone
app** — a Japanese **reader** that plays TTS audio with **word-synced
highlighting**, furigana, and tap-to-define. It is NOT the Jisho dictionary.

The char→token sync risk is **retired** and the product app (working name
**Yomi**, target `Reader`, bundle `app.reader.app`) is **built to the claude.ai
"Yomi" design and verified on the iPhone-17 sim**: Library / Reader / Dictionary
screens, three themes, vertical + horizontal Japanese text, real
ElevenLabs-via-Worker TTS, and an on-disk cache.

> The sibling folders under `~/Projects/j/` (`ios-native`,
> `jisho`, `jisho-data`, `howling-circuit`) are **code/structure references
> only** — crib patterns, do not depend on or modify them as part of this app.
> Two *data* reuses are planned: the dictionary DB under `../jisho-data` (a
> compact build feeds tap-to-define), and the production TTS proxy lives in
> `~/Projects/cloudflare/aiwork`.

Origin: built 2026-06-27 from the research doc
`~/Downloads/compass_artifact_wf-4cdbfa2f-…_text_markdown.md` (full landscape:
ElevenLabs/Polly/Azure/Google, JMdict licensing, EPUB routes). The UI came from a
claude.ai design ("Yomi") generated via `docs/design-prompt.md`. This file is the
working state; `docs/char-token-sync.md` is the deep dive on the one hard algorithm.

## The thesis (why this app exists the way it does)

TTS engines return **per-character** timings. Japanese has **no spaces**, so word
boundaries can only come from a tokenizer, and the character timings must be
**folded onto token spans**. That char→token mapping was the *only* genuinely hard
risk; everything else (furigana rendering, dictionary lookup, audio playback, file
parsing) is solved-problem plumbing. So the project was built **spike-first**:
prove the sync (done), then build the app around it (done — base UI).

**Single source of truth:** one MeCab tokenize pass per chapter yields, from the
same token list: (a) word spans for highlight sync, (b) kana readings for furigana,
(c) `dictionaryForm` (kanji lemma) for dictionary lookup. Never introduce a second
segmentation (e.g. consuming Polly/Azure word marks) — it will disagree with the
furigana segmentation. See research doc §4 "Verdict".

## Stack & key decisions (made with the user; do not relitigate without cause)

- **TTS + char timings:** ElevenLabs `POST /v1/text-to-speech/{voice}/with-timestamps`
  (`eleven_multilingual_v2` quality / `eleven_flash_v2_5` cost). Returns
  `alignment.{characters, character_start_times_seconds, character_end_times_seconds}`.
  **Always use `alignment` (original text), never `normalized_alignment`** — default
  `apply_text_normalization=auto` can rewrite numbers/dates, and only `alignment`
  tracks the displayed/tokenized text. Per-request cap: **10k chars** (multilingual_v2)
  / 40k (flash) → long chapters are split by `Chunker` (9k cap) and re-stitched by
  `AlignmentStitcher`, transparently via `ChunkingTTSService` (Phase 7, DONE).
- **TTS access (production path, WIRED):** the **`aiwork` Worker** route
  **`POST /tts/aligned`** (`~/Projects/cloudflare/aiwork/src/index.ts`) proxies
  ElevenLabs and returns the JSON verbatim. It sits **below** the global
  `app.use(revenueCatAuth)` gate (line 340) so it requires a subscribed `X-User-ID`.
  **Deployed & smoke-verified** (2026-06-27): `POST /tts/aligned` returns 401 without
  `X-User-ID`, 403 for a non-subscriber. A live **synthesis** test still needs a
  genuinely subscribed user (standing blocker) — on the sim:
  `READER_FORCE_WORKER=1` + `READER_USER_ID=<subscribed id>`.
- **Tokenizer:** **MeCab-Swift + IPADic** pinned `0.8.0`. Chosen over `NLTokenizer`
  (no readings/POS for JP). Tokenizes with **`.katakana`** transliteration, NOT
  `.hiragana`: under `.hiragana` Mecab-Swift hiragana-izes the **dictionaryForm** too
  (生まれる→うまれる), breaking lookup — so we keep the kanji lemma and convert the
  katakana reading to hiragana ourselves (`MeCabTokenizer.hiragana`). Bundle ~50 MB,
  **lazy-loaded** off the launch path.
- **Normalization:** NFKC **once**, before BOTH tokenizing and TTS (`Normalize.nfkc`),
  and as the `ContentKey` cache-key input. The capture script `.normalize('NFKC')`s too.
- **Audio:** `AVAudioPlayer` + `CADisplayLink` in `ReaderModel`; the highlight advances
  via `SpanTimeline.index(at:)` each frame. Upgrade to AVAudioEngine sample-time only if drift appears.
- **Caching (real):** `DiskAudioStore` is content-addressed by `ContentKey` =
  `sha256(nfkc(text)+voice+model)`, storing `<key>.mp3` + `<key>.json` (alignment +
  text). `ReaderModel` does load-or-synthesize, so re-reads play from disk, offline.
  `DiskLibraryStore` persists the shelf.
- **Monetization / gate (audio-only, lazy synth):** the subscription gates **only speech
  generation**. Reading — tokenize, furigana, tap-to-define, import, chapter nav, themes,
  settings — is **free**. `ReaderModel` splits `LoadState` (surface: loading/ready/failed)
  from `AudioState` (locked/idle/synthesizing/ready/notGenerated/failed). Synthesis is
  **lazy** (first Play): a free user sees a "Listen with Membership" pill, a subscriber
  generates on demand; already-cached audio loads on open. The reader renders text from
  `SpanTimeline(untimedTokens:)` (no alignment) so the moving highlight is the only
  audio-dependent piece. The local `isSubscribed()` check (RevenueCat `reader Pro`) only
  decides locked-vs-idle; the Worker's 403 stays the server-side backstop.
- **Settings:** a themed sheet from the home-header **gear** (`SettingsView`/`SettingsModel`):
  **reading font** (Mincho / Gothic / Rounded → `HiraMin`/`HiraKaku`/`HiraMaru` PS names)
  + **text size** (S/M/L scale). The font *face* applies to the reader body **and** the
  library/reader titles; the size to the reader body only. The theme toggle moved **out of
  the home header into the reader**. Theme + font + size persist via `UserDefaults` (loaded
  in `AppModel.init`, written on `didSet`).
- **Design / UI:** built to the claude.ai **Yomi** design. All visual tokens (colors,
  highlight) live in a `Theme` injected via the **SwiftUI Environment** — switching
  theme swaps the env `Theme` (the "CSS variables" analogue; never pass theme props).
  Three themes: paper / sepia / night. The reading surface is a **custom CoreText view**
  (`RubyTextView`), see Invariants.
- **i18n:** `L10n` + `en`/`ja` `.lproj`. **Chrome** localizes by system locale; **reader
  content** (the Japanese text, furigana, dictionary headwords) is always Japanese.
  Wordmark localizes 読み↔Yomi; chrome controls are **SF Symbols** (language-neutral —
  `IconButton` renders `Image(systemName:)`; the old 縦/横, 紙/茶/夜, 会, 目, + kanji
  glyphs are gone). `ThemeName.symbol` maps paper/sepia/night → sun.max/sunset/moon.stars.
- **Dictionary (DONE):** real tap-to-define via `SQLiteDictionaryService` over a
  **compact DB**. `scripts/build-compact-dict.sh` trims `jisho-seed.db` (275 MB) to
  **43 MB** by dropping the FTS5 tables + the `search_ngrams` column and keeping one
  example per word — **full word coverage retained** (lookup uses `idx_words_word`, not
  FTS). Bundled at `app/Reader/Resources/jisho-compact.db` (gitignored, regenerable),
  opened `immutable=1`. Lookup keys on `dictionaryForm`, disambiguates homographs with
  the MeCab reading, displays `words.reading`. Falls back to `MockDictionaryService` if
  the DB resource is absent.

## Layout

```
reader/
├── README.md                         # human-facing quick start + status table
├── CLAUDE.md                         # this file (working state)
├── docs/
│   ├── char-token-sync.md            # DEEP DIVE on the mapping algorithm — read before touching CharTokenMapper
│   └── design-prompt.md              # the prompt that produced the claude.ai "Yomi" design
├── scripts/
│   ├── capture-alignment.mjs         # one-off ElevenLabs capture → fixtures/ (you run it with your key)
│   └── build-compact-dict.sh         # jisho-seed.db (275MB) → app/Reader/Resources/jisho-compact.db (43MB)
├── ReaderCore/                       # SwiftPM package — all non-UI logic + contracts, swift test-able on macOS
│   ├── Package.swift                 # iOS 17 / macOS 13; dep: Mecab-Swift 0.8.0 (+ IPADic)
│   ├── Sources/ReaderCore/
│   │   ├── Alignment.swift           # Alignment (Codable) + TimestampedAudio (ElevenLabs response)
│   │   ├── Normalize.swift           # NFKC (the single-normalization rule)
│   │   ├── TokenSpan.swift           # Token / TokenSpan — both carry surface+reading+dictionaryForm
│   │   ├── JapaneseTokenizer.swift   # protocol + MeCabTokenizer (.katakana + manual hiragana)
│   │   ├── CharTokenMapper.swift     # ★ two-pointer char→token mapping + monotonic clamp
│   │   ├── Chunker.swift             # ★ lossless sentence-boundary split under the TTS char cap
│   │   ├── AlignmentStitcher.swift   # ★ offset+concat segment alignments+audio → one narration
│   │   ├── JapaneseTextDecoder.swift # .txt encoding sniff (UTF-8→Shift-JIS→EUC, mojibake-rejecting)
│   │   ├── SpanTimeline.swift        # [TokenSpan] + index(at:) highlight lookup (tested)
│   │   ├── ContentKey.swift          # sha256(nfkc(text)+voice+model) cache key
│   │   ├── Document.swift            # Document / Chapter / ReadingProgress (library models)
│   │   ├── Voice.swift               # Voice (.george) / SynthesisModel
│   │   ├── TTSService.swift          # protocol + SynthesisRequest / SynthesizedAudio
│   │   ├── DictionaryService.swift   # protocol + DictionaryEntry / Sense / Example
│   │   ├── Stores.swift              # LibraryStore / GeneratedAudioStore protocols
│   │   └── DocumentImporter.swift    # ingestion seam (spine + encoding invariants noted)
│   └── Tests/ReaderCoreTests/        # 42 green: mapper(8) + MeCab(4) + SpanTimeline(5) + Chunker(7) + Stitcher(4) + Decoder(6) + AlignmentFixture(1) + ProgressResolver(7)
│       └── fixtures/                 # captured <name>.json (commit) + <name>.mp3 (gitignored)
└── app/                              # xcodegen; .xcodeproj + build/ gitignored — edit project.yml, not the proj
    ├── project.yml                   # targets: Reader (app) + ReaderTests (importer unit tests); scheme runs both
    ├── Reader/                       # ★ the product app (Yomi)
    │   ├── App.swift  AppModel.swift  AppServices.swift  RootView.swift   # AppModel persists theme/font/size
    │   ├── Theme.swift  Components.swift  L10n.swift   # IconButton = SF-Symbol chrome; ThemeName.symbol
    │   ├── Localization/{en,ja}.lproj/Localizable.strings
    │   ├── Resources/jisho-compact.db # bundled tap-to-define DB (gitignored; build-compact-dict.sh)
    │   ├── Settings/{SettingsView,SettingsModel}.swift  # font+size sheet; ReadingFont/ReadingSize (persisted)
    │   ├── Library/{LibraryView,LibraryModel}.swift   # "+" import; home header = ★ membership / ⚙ settings / + import
    │   ├── Reader/{ReaderView,ReaderModel,RubyTextView,DefinitionSheet}.swift  # audio-only gate + lazy synth; 目→list nav
    │   └── Services/{FixtureTTSService,WorkerTTSService,FallbackTTSService,ChunkingTTSService,DiskAudioStore,
    │                  DiskLibraryStore,SQLiteDictionaryService,MockDictionaryService,SeedLibrary,
    │                  Importer,EPUBImporter,PDFImporter,TextImporter}.swift  # ZIPFoundation (app target) for EPUB
    └── ReaderTests/                  # app unit-test target — importer tests (24), runtime-generated fixtures
        └── {ImporterTestSupport,EPUBImporterTests,PDFImporterTests,TextImporterTests,ImporterRoutingTests}.swift
```

The non-UI pipeline + contracts stay verifiable headless via `swift test` (MeCab-Swift
builds for macOS); the app target is for the perceptual/visual checks.

**DEBUG launch hooks** (via `SIMCTL_CHILD_<VAR>`; on device, set them as Xcode scheme env vars):
- `Reader` app: `READER_SEED=1` (load the sample shelf — the library is **empty by
  default**), `READER_RESET=1` (wipe the persisted shelf + narration cache),
  `READER_OPEN=<library index>` (needs `READER_SEED=1` or an import), `READER_ORI=tate|yoko`,
  `READER_SEEK=<sec>` (render highlight paused), `READER_AUTOPLAY=1`,
  `READER_SHEET=<token index>` (open the definition), `READER_THEME=paper|sepia|night`,
  `READER_FONT=mincho|gothic|rounded`, `READER_SIZE=small|medium|large` (these two persist
  to `UserDefaults`, like a real change), `READER_SETTINGS=1` (open the settings sheet),
  `READER_FORCE_WORKER=1` (skip the fixture fallback), `READER_USER_ID=<id>` (test X-User-ID),
  `READER_RC_KEY=<key>` / `READER_RC_USER=<id>` (configure RevenueCat on the sim to exercise
  the locked/free tier), `READER_PAYWALL=1` (force the paywall sheet),
  `READER_WORKER_URL=<url>` (Worker base URL; from your gitignored `.env`, see `.env.example`),
  `READER_IMPORT=<host file path>` (import an epub/pdf/txt and open it),
  `READER_CHAPTERS=1` (open the chapter-nav sheet).

## Commands

```bash
# Core logic + contracts — fast, no simulator. Run after ANY change to ReaderCore.
cd ReaderCore && swift test            # 42 pass

# App-target importer tests (EPUB/PDF/Text + routing) — needs the simulator. Fixtures are
# generated at runtime (no committed binaries); see app/ReaderTests.
cd app && xcodebuild test -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build   # 24 pass

# Capture REAL ElevenLabs alignment (your key, in reader/.env as ELEVEN_KEY). Default voice = George.
node scripts/capture-alignment.mjs "吾輩は猫である。名前はまだ無い。" soseki

# Build the compact tap-to-define DB (once, before a fresh app build; output gitignored).
scripts/build-compact-dict.sh          # jisho-seed.db → app/Reader/Resources/jisho-compact.db (43MB)

# Build/run the product app (Reader / Yomi).
cp app/Signing.xcconfig.example app/Signing.xcconfig  # once: set your Team ID (gitignored; xcodegen requires the file)
cd app && xcodegen generate            # regenerate after adding files or editing project.yml
xcodebuild -project Reader.xcodeproj -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
DEV=$(xcrun simctl list devices | grep "(Booted)" | grep -oE "[0-9A-F-]{36}" | head -1)
xcrun simctl install "$DEV" build/Build/Products/Debug-iphonesimulator/Reader.app
# Deterministic screenshot, e.g. tategaki + highlight on 名前 (READER_SEED loads the samples):
SIMCTL_CHILD_READER_SEED=1 SIMCTL_CHILD_READER_OPEN=0 SIMCTL_CHILD_READER_ORI=tate SIMCTL_CHILD_READER_SEEK=1.7 \
  xcrun simctl launch "$DEV" app.reader.app

# Exercise the LIVE Worker on the sim: load secrets/config from .env, then pass
# the READER_* values into the app's launch environment. (.env is gitignored;
# copy .env.example → .env and fill it in.)
set -a; . ./.env; set +a
SIMCTL_CHILD_READER_FORCE_WORKER=1 \
SIMCTL_CHILD_READER_WORKER_URL="$READER_WORKER_URL" \
SIMCTL_CHILD_READER_USER_ID="$READER_USER_ID" \
  xcrun simctl launch "$DEV" app.reader.app

# Production TTS (USER runs these — interactive / mutates the live Worker):
cd ~/Projects/cloudflare/aiwork && npx wrangler secret put ELEVENLABS_KEY && npx wrangler deploy
```

First `swift test` compiles the MeCab C++ sources (~minute) and downloads IPADic
(~50 MB); subsequent runs are instant.

## Public API surface (ReaderCore)

- `Normalize.nfkc(_:) -> String`.
- `Token(surface:reading:dictionaryForm:)` / `TokenSpan{index,surface,reading,dictionaryForm,start,end,matchedChars}`. `matchedChars == 0` = interpolated span (diagnostic).
- `protocol JapaneseTokenizer`; `MeCabTokenizer()` (`throws`) — NFKC-normalizes internally; one pass yields surface + hiragana reading + kanji `dictionaryForm`.
- `Alignment(characters:startTimes:endTimes:)` (Codable, ElevenLabs snake_case); `TimestampedAudio` (`audio_base64`+`alignment`+`normalized_alignment`).
- `CharTokenMapper.map(tokens:alignment:options:) -> [TokenSpan]`; `Options(lookahead:)` default 8.
- `SpanTimeline([TokenSpan])` → `index(at: Double) -> Int?` (rightmost token with `start ≤ t`), `duration`; `SpanTimeline(untimedTokens: [Token])` builds a render-only (zero-timing) timeline for the no-audio reader path.
- `ContentKey(text:voice:model:)` → stable cache key (`.value`).
- Models: `Document`/`Chapter`/`ReadingProgress`, `Voice`(`.george`)/`SynthesisModel`, `DictionaryEntry`/`Sense`/`Example`.
- Protocols: `TTSService.synthesize(_:) async throws -> SynthesizedAudio` (`SynthesisRequest{text,voice,model}`, `.cacheKey`); `DictionaryService.lookup(dictionaryForm:reading:)`; `LibraryStore`; `GeneratedAudioStore.{load,save,has}`; `DocumentImporter.chapters()`.

## Invariants & conventions

- **`CharTokenMapper` is load-bearing.** Don't simplify to naive positional slicing — it breaks on every real divergence (collapsed whitespace, punctuation-as-own-char, dropped/inserted chars, surrogate pairs). Two-pointer + clamp; reasons in `docs/char-token-sync.md`. Changing it: `CharTokenMapperTests` + `AlignmentFixtureTests` must stay green.
- **`Chunker` must stay lossless; `AlignmentStitcher` must stay monotonic.** `Chunker.split(text).joined()` MUST equal the input exactly (no trimming / inserted separators) — the stitched `alignment.characters` reconstruct the chapter text 1:1, which `CharTokenMapper` depends on. `AlignmentStitcher` offsets each segment by the prior segments' spoken length so token starts stay monotonically non-decreasing across joins. Changing either: `ChunkerTests` + `AlignmentStitcherTests` must stay green.
- **`RubyTextView` is the other load-bearing piece.** UILabel/UITextView render ruby but give NO per-token geometry and can't do vertical text, so the reader surface is a **custom `CTFramesetter`/`CTFrame` draw**: ruby via `CTRubyAnnotation` (`.before` auto-rotates to the column's right in vertical); tategaki via frame `kCTFrameProgressionAttributeName=rightToLeft` + `kCTVerticalFormsAttributeName`; highlight as a drawn rounded rect behind the active token + its text recolored to `hiInk` (base runs use `kCTForegroundColorFromContextAttributeName` so the context fill colors them); taps hit-test the same per-token rects. The CTFrame is **cached** (rebuilt only on bounds/structure change, never per-highlight-frame).
- **Normalize once, identically, everywhere** (tokenizer + TTS + cache key). New ingestion paths normalize at the boundary.
- **Prefer `alignment` over `normalized_alignment`** — indices track displayed text.
- **One tokenizer, no second segmenter.** One MeCab pass feeds sync + furigana + lookup. No Polly/Azure word marks, `NLTokenizer`, or tiny-segmenter.
- **`ReaderCore` stays UI-free and `swift test`-able on macOS.** Contracts + logic here; SwiftUI/CoreText/AVFoundation in the app target only.
- **Theme via the Environment, not props.** Components read `@Environment(\.theme)`; the design hand-off is a re-skin of `Theme`, not a rewire.
- **i18n: chrome localizes, content stays JP.** Add UI strings to `L10n` + both `.lproj`; never localize reader content.
- **Fixtures are the golden record AND the DEBUG offline fallback.** Commit `fixtures/*.json`; `*.mp3` gitignored. In DEBUG the app plays them so the sim works without the Worker; release uses the Worker only.

## Validation thresholds (the spike's definition of done)

From research doc rec #1, judged on the reader over real prose: highlight lands on
the **correct token >95%** with **<150 ms perceived lag**. Headless proxy (asserted
in `AlignmentFixtureTests`): monotonic non-decreasing token starts, no NaN spans,
**char-match coverage > 90%**. If coverage is low/non-monotonic: (1) confirm both
sides NFKC-normalized identically; (2) confirm `alignment` not `normalized_alignment`;
(3) check ElevenLabs language normalization didn't rewrite the text; (4) widen
`CharTokenMapper.Options.lookahead`.

## Status (2026-06-28)

- **Phases 1–3 — sync pipeline: DONE & green.** `CharTokenMapper` + 8 adversarial tests;
  `MeCabTokenizer` (surfaces reconstruct NFKC input 1:1, kanji `dictionaryForm` extracted);
  3 captured fixtures (soseki / numbers / dialogue) at 100% char-match coverage. `2026`
  stays one token across its spoken expansion (we read `alignment`). These are 17 of the now-**42** `swift test` cases.
- **Phase 4 — product app BUILT to the Yomi design & sim-verified.** Library / Reader /
  Dictionary, 3 themes, tategaki + yokogaki with furigana, the synced highlight (correct
  glyph-rect in both orientations), tap-to-define. A `code-review` adversarial pass found
  6 issues — all fixed (CADisplayLink `deinit`, lazy IPADic load, CTFrame caching, hiInk
  recolor, error discrimination, fixture voice/model match). ⚠️ The live **perceptual**
  check (watch + listen while playing) is still the user's.
- **i18n — DONE & verified.** EN (Yomi/Unread/Done) and forced-JA (読み/未読/読了) both render.
- **Phase 5 — DONE.** Real **caching**: `DiskAudioStore` (verified writing) +
  `DiskLibraryStore` (verified persisting); load-or-synthesize wired. Real
  **tap-to-define**: `SQLiteDictionaryService` over the bundled 43 MB compact DB —
  sim-verified (猫 → the full 6-sense jisho entry + a real example, vs the old mock's
  single "cat").
- **Phase 6 — Worker route DEPLOYED & smoke-verified.** `/tts/aligned` live on aiwork
  (+`ELEVENLABS_KEY` binding in `index.ts` and `worker-configuration.d.ts`);
  `WorkerTTSService` is the release default. Smoke test: 401 without `X-User-ID`, 403
  for a non-subscriber. Remaining: a live **synthesis** test with a subscribed user.
- **Reading-progress writeback — DONE & sim-verified.** `ReaderModel.persistProgress()`
  writes `ReadingProgress(chapterIndex, time, fraction)` back via `library.save` on
  pause / leave / completion / backgrounding, and `load()` resumes the playhead. Guarded
  so a fresh/failed open never clobbers a real saved position with zeros (the resume
  guard + `currentTime > 0` check). Library 未読/N%/読了 labels now track real reading.
- **Phase 7 — ingestion + chunking: DONE & sim-verified.** Pure, tested ReaderCore
  algorithms: `Chunker` (lossless sentence-boundary split under a 9k-char cap),
  `AlignmentStitcher` (offset+concat segment alignments+audio into one continuous
  narration), `JapaneseTextDecoder` (UTF-8→Shift-JIS→EUC sniff, mojibake-rejecting) —
  **+17 tests, swift test = 34 pass.** App-target importers conforming to
  `DocumentImporter`: `EPUBImporter` (ZIPFoundation unzip → `META-INF/container.xml` →
  OPF **spine** order, `linear="no"` skipped → body-isolated XHTML strip),
  `PDFImporter` (PDFKit, one chapter/page), `TextImporter` (encoding sniff).
  `ChunkingTTSService` decorates the `TTSService` so over-cap chapters are chunked,
  synthesized with bounded concurrency (2) + 429 backoff + per-segment cache, and
  stitched — transparently to the reader/cache. The **+** button imports
  epub/pdf/txt (off-main parse); multi-chapter docs get a **目** chapter-nav sheet.
  EPUB import verified end-to-end on the sim (3-chapter spine parsed in order, library
  persists). A 5-dimension adversarial review (12 confirmed findings) was applied.
- **Monetization reworked — gate ONLY speech generation, lazy synth. DONE & sim-verified.**
  Reading (text + furigana + tap-to-define + import + chapters + themes + settings) is
  **free**; only TTS is gated. `ReaderModel` split into `LoadState` (surface) + `AudioState`;
  synthesis deferred to first Play. Sim-verified: free/unsubscribed user reads the full text
  + a "Listen with Membership" pill; subscriber gets lazy synth → correct highlight + full
  transport; cached re-reads load instantly; tap-to-define works for free users.
- **Settings + persistence — DONE & sim-verified.** Themed sheet from the home gear:
  reading font (Mincho/Gothic/Rounded, each previewed in-face) + text size (S/M/L). Font
  face reaches the reader body + library/reader titles. Theme toggle moved into the reader.
  Theme + font + size persist (`UserDefaults`) — two-launch persistence verified; EN + JA
  settings both render.
- **Chrome → SF Symbols + i18n sweep — DONE & sim-verified.** All header glyphs replaced
  with language-neutral SF Symbols (★ membership / ⚙ settings / + import / ☰ chapters /
  ↕↔ orientation / ☀🌇🌙 theme). Remaining hardcoded chrome localized (alert OK,
  chapter-number fallback, cached-audio a11y) + all settings strings, en + ja.
- **Importer tests — DONE & green (NEW: first app-level tests).** A `ReaderTests`
  `bundle.unit-test` target (hosted by `Reader`, deps ZIPFoundation + ReaderCore) with
  **runtime-generated fixtures** — EPUB zipped via `FileManager.zipItem`, PDF via
  `UIGraphicsPDFRenderer`, text in UTF-8/Shift-JIS/EUC-JP/BOM — **24 cases** over
  EPUBImporter (spine order, `linear="no"` skip, head isolation, entity decode, nested/%-href,
  corrupt→unreadable, empty-spine→empty), PDFImporter (per-page, blank-skip, unreadable),
  TextImporter (encodings, BOM, empty), and `Importer` routing. All three formats also
  re-verified end-to-end via `READER_IMPORT` (real .epub/.pdf/.txt opened in the reader).

## Not done yet / next

- **Live Worker synthesis test** (user): the route is deployed + gated; remaining is one
  real synth with a subscribed `X-User-ID` — on the sim set `READER_FORCE_WORKER=1` +
  `READER_USER_ID=<id>`, or `wrangler dev` + `.dev.vars` locally. This is also the only
  way to perceptually verify chunk→stitch on a long imported chapter (sim has no TTS).
- **Ingestion follow-ups (deferred, LOW — from the review):** (a) chunked chapters store
  both per-segment AND the stitched whole-chapter entry in the evictable Caches dir —
  prune the segment entries after a successful stitch; (b) `LibraryModel.load` re-hashes
  each doc's first-chapter text (SHA-256) on the main thread every appearance — memoize
  the `ContentKey` or compute off-main once the library holds many large imports.
- **Reading-override table** for homograph furigana (頓→とん, 月→がつ) — furigana-quality only.
- Optional: in-app language toggle; AVAudioEngine if sync drift appears; batch pre-gen
  (download-all-for-offline) reusing `ChunkingTTSService`'s backoff.

## Reuse map (sibling files to crib from — copy patterns, don't import)

- Furigana attributed-string builder (`CTRubyAnnotation`): `ios-native/Jisho/Jisho/Furigana.swift`
  — the ruby technique carried into `RubyTextView`, but the reader needed a **custom CoreText
  draw** (vertical text + moving highlight) instead of its UILabel/UITextView hosts.
- Raw read-only SQLite over the C API: `ios-native/JishoCore/Sources/JishoCore/Database.swift`.
- iOS Worker client (X-User-ID, 403→subscription): `ios-native/JishoCore/Sources/JishoCore/AIRemote.swift`.
- xcodegen multi-target / Info.plist (background audio): `ios-native/Jisho/project.yml`.
- Worker route style / auth / env: `~/Projects/cloudflare/aiwork/src/index.ts` (`/sound`, `/tts/aligned`).
- Dictionary DB: built by `../jisho-data` (`npm install && npm run db:build`).

## Decisions log

- Separate, new app — siblings are references only (user, 2026-06-27).
- Spike-first: prove char→token sync before any UI (user).
- ElevenLabs with-timestamps, proxied via `aiwork` Worker `/tts/aligned` (user; route built 2026-06-27).
- MeCab-Swift + IPADic over NLTokenizer; tokenize with `.katakana` to keep the kanji lemma (user/impl).
- Built to the claude.ai "Yomi" design; visual tokens behind a `Theme` in the Environment (user).
- i18n: system-locale chrome, JP content; wordmark localized, toggle glyphs iconic (user).
- Real path now: Worker TTS + `DiskAudioStore` cache + persisted library; fixtures = DEBUG fallback only (user).
- Dictionary: build a **compact** DB from sources rather than bundle the 288 MB seed (user).
- Phase 7 ingestion: pure/tested algorithms (`Chunker`, `AlignmentStitcher`, `JapaneseTextDecoder`) in
  ReaderCore; format importers (EPUB/PDF/Text) in the app target (need PDFKit/ZIPFoundation) (impl, 2026-06-28).
- **ZIPFoundation** (app target only, pinned `from: 0.9.0` for the failable `Archive` init) for EPUB unzip —
  no public system unzip exists on iOS; reinventing a ZIP reader is the opposite of simple. ReaderCore stays 1-dep (impl).
- Chunking is a **`TTSService` decorator** (`ChunkingTTSService`), so the reader + cache are unchanged: one
  request → one stitched `SynthesizedAudio` keyed by the whole-chapter `ContentKey` (impl, 2026-06-28).
- Imported books keep chapter structure (one Chapter per EPUB spine item / PDF page) + a minimal in-reader
  **目** chapter-nav sheet, rather than flattening a whole book into one giant synthesis (impl, 2026-06-28).
- **Library starts empty** (real app): the sample shelf (`SeedLibrary`, with its canned progress) is dev-only,
  opt-in via DEBUG `READER_SEED=1`; `READER_RESET=1` wipes the persisted shelf + narration cache without an app
  delete (keeps the RevenueCat appUserID). Empty first-run shows a "Your library is empty" hint (user, 2026-06-28).
- **RevenueCat wired** (minimal): `Purchases.configure` at launch with the iOS public key (`READER_RC_KEY` env /
  `RevenueCatKey` Info.plist); `Purchases.shared.appUserID` becomes the Worker's `X-User-ID` (DEBUG `READER_USER_ID`
  overrides for tests). The `aiwork` Worker verifies the standalone `reader` RevenueCat project for `/tts/aligned`
  only (`projectCreds()`, `REVENUECAT_*_READER`), default project for jisho's routes — two apps, one Worker (user, 2026-06-28).
- **Gate ONLY speech generation**, not the whole reader: reading is free, audio is the paid
  feature. Synthesis is **lazy** (on Play), not eager on open — saves TTS cost on
  opened-but-unheard chapters. Free-user audio UI = a single "Listen with Membership" pill
  (user, 2026-06-28).
- **Settings screen** (font + size) reached from the home-header gear; theme toggle moved
  out of the home header into the reader. Reading **font face** applies to body + titles,
  **size** to the body only. Theme + font + size persist via `UserDefaults` (user, 2026-06-28).
- **Chrome controls → SF Symbols** (language-neutral), replacing the single-kanji glyph
  buttons; membership icon is `star.circle` (user chose over crown). Reader content + the
  read-direction nature of orientation kept the glyphs' intent via arrows/appearance icons
  (user, 2026-06-28).
- **First app-level test target** (`ReaderTests`): the EPUB/PDF/Text importers live in the
  app target (need ZIPFoundation/PDFKit) so they can't go in headless ReaderCore — fixtures
  are generated at runtime instead of committing binaries (impl, 2026-06-28).
