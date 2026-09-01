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
the `TokenizerWorker` actor (app target): off the main thread — opening the dictionary is cheap
(it is `mmap`ed) but first-touch page faults across 49 MB and the per-chapter tokenize used to
freeze the reader-open transition — and serialized. The engine no longer forces that
serialization: `MeCabTokenizer` binds MeCab's **lattice API** (one lattice per call over a shared
tagger), where the mutable parse state lives in the lattice, so concurrent parses would be safe.
It stays serialized by design. Never tokenize on the main actor. `MeCabTokenizer` builds every
surface as a byte slice of the NFKC text, taken from `node.surface`'s offset into the parsed
buffer, and emits the whitespace MeCab drops as untimed gap tokens — so both
`joined(surfaces) == nfkc(text)` and `sum(surface.count) == nfkc(text).count` hold, and
paragraphs / line breaks / indents survive to the page. Both invariants are load-bearing: the
second is what `TokenOffsets` (saved reading position), `SourceReadingOverlay` (publisher ruby)
and `PronunciationLexicon` walk on, and a surface that splits a grapheme cluster drifts every
later token in the chapter. `ClusterProjection` is what keeps it true — it strips variation
selectors before the parse (so 葛󠄀城 stays one word) and snaps node boundaries outward onto
`Character` boundaries. See `docs/2026-08-14-tokenizer-alternatives.md`.

## Architecture

Two modules. The split is load-bearing: **all non-UI logic + contracts live in `ReaderCore`,
which is headless and `swift test`-able on macOS** (no simulator). SwiftUI / CoreText / AVFoundation /
PDFKit / networking live in the `app/` target only.

- **`ReaderCore/`** (SwiftPM; MeCab 0.996 vendored in `Sources/CMeCab`, dictionary from the
  Mecab-Swift package's `IPADic` product) — `CharTokenMapper`, `Chunker`,
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
  wrapped by `ChunkingTTSService` — **dormant by design since 2026-09-01**: a displayed chapter is
  capped at `Chapter.renderableHardMax` (1400) which is below `SynthesisLimits.maxRequestChars`
  (1500, or whatever `/tts/voices` serves for the configured model), so **one chapter is exactly one
  request** and the chunked path never fires. That is not an optimization — `eleven_v3` ends every
  request with 1.5-2.2 s of speech its alignment does not describe, so each extra request would put
  another mid-chapter freeze of the highlight into the book. See
  `.claude/notes/investigations/2026-09-01-v3-unlabelled-tail-and-one-request-per-chapter.md`.
  If it does fire it is sequential and publishes under the PARENT key with a running
  `SynthesizedAudio.stitchAdvance` offset, so what the reader streams equals what is sealed;
  exponential 429 backoff on **both** the chunked and single-request paths;
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
  ends; it honors Reduce Motion, and stops itself when settled. It yields to manual drags via a
  `userParked` latch set in `scrollViewWillBeginDragging` and released only when `activeIndex` next
  moves (or the chapter changes) — guarding merely on `isDragging`/`isDecelerating` is NOT enough,
  because the link then resumes the instant deceleration ends and hauls the reader back to the
  highlighted line. Measured before the latch: a 10356 pt pull, on any chapter that had ever been
  played, since `activeIndex` is cleared only in `openChapter` and so survives pause.
  **`LoadState` (the always-available reading surface) is split from `AudioState`** (the gated synth
  lifecycle: `.locked`/`.idle`/`.synthesizing`/`.ready`/`.notGenerated`/`.interrupted`/`.failed`).
  **A suspension is not a failure.** Being killed mid-generation by the app going to the background
  arrives as a `URLError` like any other, and rendering that as terminal `.failed` was the "synthesis
  error on unlock" bug; `ReaderModel` records that it was backgrounded while `.synthesizing` and
  routes those through `stateAfterSynthesisFailure` to `.interrupted`, leaving a real network
  failure looking like one. On return, `ReaderView`'s `scenePhase == .active` branch reconciles
  before anything is shown: cache first (the run may have completed), then re-attach to a task
  `SynthesisCoordinator` still holds. **Narration already delivered is kept, not discarded.** If
  playback had started, the partial is handed to `swapInExactAudio` — NOT sealed in place, because
  the advertised `contentLength` was an estimate for the whole chapter made before the first byte
  arrived, and a player that believes the track is longer than it is stalls at the truncated end
  (`MEDIA_PLAYBACK_STALL`) instead of firing `didPlayToEndTime`. Rebuilt at its true length it
  reaches a real end, lands in `.interrupted`, and neither auto-advances nor marks the chapter
  read. It is never saved: a truncated stream must not cache under a key promising a whole chapter.
  Progress
  writeback goes through `ReadingProgressResolver` (tested), never per frame; free (no-audio)
  reading persists at least the chapter position. **Open a book through
  `services.library.current(document)`, never from the `Document` a view is holding** —
  `RootView` animates the route for 0.25 s, so `LibraryView.onAppear` reloads the list BEFORE the
  departing reader's `.onDisappear` writes, and the list's copy is then one save stale; that is the
  "resume is always one position behind" bug. `ReadingProgress` also stores ONE position per book,
  so moving to another chapter overwrites the previous chapter's offset — by design, not a bug.

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
  is split into sub-chapters of about `Chapter.maxRenderableChars` (1000, hard cap
  `Chapter.renderableHardMax` 1400) by `Chunker.splitForReading`, titled `"<title> (n)"`.
  It cuts at a **paragraph** boundary, falls back to a sentence, and hard-splits only a sentence
  longer than the cap. A book chapter becomes several of ours — 47 → 149 on a Euphonium volume —
  and that is deliberate: see the one-chapter-one-request invariant below.

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
- **A reading the book printed outranks the tokenizer's guess, including where the two disagree
  about word boundaries.** MeCab segments by grammar; ruby marks a word. `SourceReadingOverlay`
  therefore JOINS the token run an annotation covers (`joiningAcrossAnnotations`) before overlaying
  — measured over the bundled starter books, accepting only annotations that fit inside one token
  discarded 305 of 1881, 139 of them readings the tokenizer got wrong (兵十 ひょうじゅう → へいじゅう,
  洋杖 ステッキ → ようつえ). Joining keeps both stream invariants and moves the cut onto the boundary
  the book itself drew; it supersedes the earlier "carried but not applied" rule (7698541), whose
  concern — identical starts defeating `SpanTimeline.index(at:)`'s rightmost search — was a hazard
  of spreading one reading over two SURVIVING tokens, and cannot arise when they become one. A
  joined token drops its `dictionaryForm` (its parts' lemmas describe pieces); tap-to-define already
  falls back to the surface. The refusal that REMAINS deliberate: an annotation covering part of a
  token whose remainder is not kana (掻 ruby'd か inside 掻き立て) is still dropped whole — and the
  join is gated on that SAME composition test, so a refused annotation never costs a lemma or a
  highlight boundary either (ruby 茶碗 over the tokens 御茶 + 碗 leaves both tokens standing).
- **A displayed chapter is exactly ONE TTS request** (2026-09-01). `Chapter.renderableHardMax`
  (1400) must stay at or below `SynthesisLimits.maxRequestChars` (1500, or whatever `/tts/voices`
  serves for the configured model), pinned by `testADisplayedChapterAlwaysFitsInOneRequest`.
  The reason is `eleven_v3`: **every request ends with 1.5-2.2 s of speech its alignment does not
  describe** (measured, RMS -45 dB to -11 dB past `endTimes.last`). At one request per chapter that
  tail lands after the last sentence and nobody notices; split a chapter into N requests and N-1 of
  those tails land mid-chapter, freezing the highlight for seconds at a time while words are spoken.
  Raising the cap back re-creates that. See
  `.claude/notes/investigations/2026-09-01-v3-unlabelled-tail-and-one-request-per-chapter.md`.
- **One CoreText frame per chapter, rasterized through tiles this app owns.** The cap
  (`Chapter.maxRenderableChars`) does NOT keep the surface under the platform texture limit,
  and never did: measured 2026-08-25, a 4k chapter is 999x44664 px in yokogaki (999x60859 at the
  large size) and 25311x2100 in tategaki (36333x2100), against a 16384 px limit — a 180-300 MB
  backing store. 1000 chars is the only cap that fits, with 6.7% to spare — which the 2026-09-01
  cap now satisfies for a different reason. So the cap is a *layout/tokenize* budget, not a texture
  guard; the texture guard is the tiling.
  `RubyContentView` therefore draws with `CTFrameDraw` into each tile's translated context —
  pixel-identical to drawing the whole frame in both orientations (0 differing pixels of 210800),
  and ~1.7 ms per tile, off the main thread. **Do not "optimize" that into per-line `CTLineDraw`:**
  it matches exactly in yokogaki but diverges 16.8% in tategaki, because vertical progression lives
  in the frame, not the line (`CulledLineDrawProbeTests` pins both halves).
  **The tiles are NOT a `CATiledLayer` and must never go back to being one** (2026-08-27): CA draws
  such a layer on `CAImageProviderThread` and commits a CATransaction there, and that commit
  flushes pending layout for the WHOLE layer tree — including the SwiftUI host this view lives in.
  SwiftUI then runs `DisplayList.ViewUpdater` off the main actor and traps in its own
  `MainActor.assumeIsolated`. It crashed on any hard scrub, with no frame of ours anywhere on the
  stack: TestFlight 1.10 (76) on iOS 27.0 and the iOS 26.5 simulator both, and the same race left
  chapters blank when it landed the other way. Tiles are therefore plain `CALayer`s inserted below
  `highlightLayer`; each is rendered into a raw `CGContext` on a private serial queue and its
  `contents` assigned on the main thread. That context already has a bottom-left origin, so the
  `translateBy(0,h)`/`scaleBy(1,-1)` flip the old `draw(_:)` needed for UIKit's flipped context is
  gone — the tile transform is exactly the one `CulledLineDrawProbeTests` measures.
  `RubyScrollView.scrollViewDidScroll` decides which tiles are wanted, with one tile of margin
  along the scroll axis ONLY: margin on both axes costs >100 MB of backing store at @3x. The
  `CTFrame` and ink colour are captured on the main actor when a tile is scheduled, so the render
  queue never reads mutable state, and `tileGeneration` discards tiles that land after a reflow.
  Import splits oversized chapters at PARAGRAPH boundaries, falling back to sentences
  (`Chunker.splitForReading`; a single sentence longer than the cap is hard-split, which real prose
  never triggers). Raising the cap costs main-thread layout AND re-creates the mid-chapter freeze
  above; lowering it re-keys `ContentKey` and strands paid audio.
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
- **The app decides WHAT to read, in WHICH VOICE, and HOW ITS OWN BOOK IS PRONOUNCED; the
  Worker decides everything else.** The request body is `{text, voice_id, stream}` plus an
  optional `pronunciation_rules` — the book's own publisher ruby, derived by
  `PronunciationLexicon` (see `docs/2026-08-07-pronunciation-dictionaries.md`). That last field
  is an amendment, not a loophole: the rule exists to stop *generation parameters* drifting back
  to the client, and a reading printed in the book is not a generation parameter — it is content
  only the client has. ElevenLabs accepts only a dictionary *locator* on a synthesis request, so
  the rules must reach the Worker for it to create that dictionary; there is no design in which
  they don't. The Worker re-validates every rule (kana-only, ≥2 chars, must occur in the
  submitted text, capped) because they are spent against our own account, and resolves the
  surviving set to a pinned locator by canonical hash, so the same text resolves to the same
  dictionary on every device.
  **A rule's base does not have to be a WORD — it has to be a string whose reading the book
  vouches for at every occurrence** (2026-08-27). That is why `tokenSpans` widens a
  single-character annotation past its own token: `己 → おれ` cannot be sent (≥2 chars, and a
  one-character alias is unsafe as a substring — 橋 inside 日本橋), but `己の → おれの` can, and
  widening also makes the string rare enough that its only occurrence is the annotated one. The
  composition is annotations plus literal kana ONLY: filling an unannotated kanji from MeCab and
  calling it vouched is not proof. Shortest window wins, ties go to the window headed by the
  annotated token, and the existing gates do the vouching — `unannotatedOccurrence` already IS
  the "every literal match must agree" check, so nothing was relaxed to make this work. Measured
  over the eight starter books: rules cover 79% of the sites where MeCab disagrees with the book,
  up from 44%. Bound readings (`面 → づら`, which exists only inside 横っ面) are legitimate phrase
  rules, not an excluded class. Still unmeasured, and the reason not to widen further: ElevenLabs'
  precedence among OVERLAPPING rules is undocumented, and the lexicon already emits overlapping
  pairs today (飛込 ⊂ 飛込ん, ご馳走 ⊂ 馳走). See
  `.claude/notes/investigations/2026-08-27-ruby-lexicon-coverage.md`. Note the occurrence filter runs BEFORE the hash, so identity is
  currently per CHAPTER, not per book — deterministic and correct, but it mints one
  undeletable dictionary per chapter read (§11 of the findings doc, incl. the fix). The model,
  `language_code` and the five `voice_settings` live in aiwork's `src/tts.ts` (model overridable
  via the `TTS_MODEL` var), so narration is re-modelled or retuned **without an App Store
  release**. `stream` stays client-sent
  because it declares "I can consume NDJSON" — a fact about the client, not config — and the Worker
  defaults it too. **The Worker also OWNS the voice line-up** (2026-08-20): `TTS_VOICES` in
  `src/tts.ts` is the one definition, the allow-list is derived from it, and `GET /tts/voices`
  serves the selectable subset — so adding or retiring a voice is a deploy, not an App Store
  release. The client keeps `Voice.seed` only as an offline fallback. A `retired` voice stays
  allow-listed forever: the cache key includes the voice, so de-listing one would strand paid
  audio. An explicitly-sent `model_id` still wins server-side, for builds shipped before the
  move — don't "clean that up" until those age out.
- **Every `SynthesisRequest` must carry the selected narration voice** (`services.narrationVoice`,
  mirrored from `AppModel`) — the voice is the only thing besides the text in `ContentKey`, so a
  defaulted request silently misses the cache and re-bills synthesis. Current sites: `ReaderModel`
  (eager probe + synth), `AppServices.firstChapterKey` (library ↓ badge; memoized, invalidated on
  voice change), `purgeAudio` (sweeps `VoiceCatalog.knownIDs` — an append-only union of
  `Voice.allKnown` and every id ever served — **x** every key a probe can resolve, i.e.
  `cacheKeyCandidates`; anything `loadAllowingLegacyModel` finds must be reclaimable. It must
  never depend on the network: purge runs on swipe-to-delete, possibly offline).
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
  `language_code: "ja"` — it was pinned because without it the multilingual pipeline resolved kanji
  through *Chinese* (日本橋 as "Ri Ben Qiao"). Treat that as why it exists, not as a guarantee it
  still provides: ElevenLabs documents `language_code` as unsupported on `eleven_multilingual_v2`,
  and a 2026-08-20 probe read it correctly with AND without the flag (on kana-rich text, the
  friendly case). Still sent — accepted and free if ignored — but not the defense it reads as. `voice_settings` are sent explicitly so a shared-library
  voice's own saved settings don't decide delivery; they are deliberately NOT in `ContentKey`, so
  retuning them does not invalidate paid audio. **Never send
  `apply_language_text_normalization`** — it is an LLM pass that speaks its own reasoning aloud
  ("Wait, let me redo this properly: …"), 4x duration, one char absorbing 15 s of alignment
  (measured 2026-07-29). The Worker builds the upstream body field by field so it cannot reappear;
  `test/tts.test.ts` there and `WorkerTTSServiceTests` here both assert it stays off the wire.
  The default model is `eleven_multilingual_v2` (since 2026-08-20): `eleven_flash_v2_5` reports
  `can_use_style`/`can_use_speaker_boost` false and SILENTLY DISCARDED two of the five pinned
  `voice_settings`, and `apply_text_normalization` is Enterprise-only there. `ttsVoiceSettings`
  now shapes the settings per model so that can't recur. Costs ~2.44x per audio hour. `eleven_v3`
  is still not the default — its alignment defect has fallen below the client's 1 s guard but not
  vanished (see `docs/2026-08-03-findings.md` and
  `.claude/notes/investigations/2026-08-20-elevenlabs-model-and-voice-audit.md`).
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
- **The library is seeded once with the eight bundled starter books; everything after that is the
  user's own import.** `AppModel.seedStarterBooksIfNeeded` arms only when `DiskLibraryStore`
  had to create `library.json` (`wasCreated`) — a fresh install, never a launch into an existing
  library, however empty the user has since made it — and the same eight stay reachable from the
  `+` menu → *Sample Books* (`StarterBooksView` → `importStarterBook`). Both paths parse across a
  suspension, so both re-check `libraryContains` on the main actor between the parse and the save:
  seeding and a manual add of the same title race otherwise, and each would persist its own row
  under a fresh UUID. Arming writes the eight ids to `reader.starterSeedPending` BEFORE the first
  save, and each id is struck only once its own `library.flush()` reports the write landed — so a
  seed interrupted by a kill, a crash or a failed write resumes on the next launch, when
  `wasCreated` is already false and can no longer be the trigger. See `docs/starter-books.md`.
  Swipe-to-delete a row also purges its
  cached narration (`AppServices.purgeAudio`). Settings has a "clear audio cache" control
  (`audioStore.clear()` / `totalBytes()`). Reading font/size/orientation/furigana + theme + the
  narration voice (by id, resolved through `VoiceCatalog`, falling back to Shizuka) persist via `UserDefaults` in
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
