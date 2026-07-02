# Code-review fixes (2026-07)

A full review of the app turned up correctness, data-safety, TTS/cache, and import issues; this is
the record of what changed. Findings were verified adversarially, then the fixes were verified by
`swift test` (ReaderCore + app target) and by driving the running app on the simulator via
`scripts/uitest/`. Landed as one series on `master` (see `git log`).

## Data safety
- **`DiskLibraryStore` writes atomically** and, on a decode failure of an existing `library.json`,
  preserves the bad file as `library.json.corrupt` instead of overwriting the shelf with an empty
  one. `library.json` is the only copy of imported text.
- **`DiskLibraryStore` persists off the main actor** (serial queue, COW snapshot) — a progress save
  no longer re-encodes every book's full text synchronously on the main thread.
- **`WorkerTTSService` rejects malformed alignment** (empty / mismatched parallel arrays) instead of
  trapping downstream; `Alignment.startTime/endTime(at:)` stay total on empty arrays.

## TTS pipeline + cache
- **300 s synthesis timeout** on `/tts/aligned` (the route buffers the whole response; the old 30 s
  idle timeout failed long chapters while ElevenLabs still billed the abandoned generation).
- **Single-request (short-chapter) path gets the 429 backoff too** (was chunked-path only).
- **`ChunkingTTSService` saves the whole chapter durably before pruning per-segment entries**, so a
  crash in that window can't lose every paid segment.
- **`ReaderModel` nils the player on teardown** and cancels the in-flight synth task on leave (bumps
  `loadGeneration`), so a stale player can't replay under a new chapter and a reopen can't run a
  duplicate paid synthesis.
- **Background audio:** `AVAudioPlayerDelegate` marks completion (read = 読了) even when locked, and an
  `AVAudioSession` interruption observer pauses/resumes across calls/Siri; the session is activated in
  `play()` (not on chapter open, which used to duck other apps) and deactivated with
  `.notifyOthersOnDeactivation` on teardown.

## Import + text fidelity
- **EPUB `<rt>/<rp>` ruby content is stripped** so furigana isn't inlined/doubled into the body.
- **`MeCabTokenizer` preserves whitespace** (emits gap tokens via `annotation.range`), so paragraphs
  / line breaks / indents survive; `joined(surfaces) == nfkc(text)`.
- **`JapaneseTextDecoder` scores candidate encodings** (fixes EUC-JP → Shift-JIS half-width-katakana
  mojibake) and falls back to a repairing UTF-8 decode instead of a second strict one.
- **Import orchestration moved to `AppModel`** so it survives Library↔Reader route switches (progress
  banner / errors / result no longer lost on navigation), reachable via `+` and `onOpenURL`
  (`CFBundleDocumentTypes` — Open in Yomi from Files / share sheet).
- **Mixed text+scanned books** now offer OCR for the image-only pages after a successful text import
  instead of silently dropping them; declining/OCR-failure saves the text-only fallback.
- **Oversized chapters are split at import** into ≤ `Chapter.maxRenderableChars` (~4k) sub-chapters —
  the reader draws one CoreText surface per chapter, and a bigger one renders blank / hangs the main
  thread (measured on-simulator). Fixes a whole-novel `.txt` imported as one chapter.
- **EPUB has a decompressed-size cap** (zip-bomb / oversized entry fails cleanly, no OOM).
- Image-only EPUB for a non-subscriber surfaces `.ocrUnavailable` (Membership prompt), not `.empty`.

## Rendering + UI
- **Night theme rendered black-on-black** — the base text used the CoreText context fill, which the
  first ruby annotation corrupts (invisible in paper, fatal in night). Now every run + ruby carries
  an explicit ink color; a theme switch rebuilds the string.
- **The moving highlight is a `CAShapeLayer`** so advancing it ~60×/sec never repaints the chapter;
  tap hit-testing uses cached line geometry (O(tokens), not O(tokens×lines)).
- **The library didn't scroll** once books exceeded one screen — the `List` sized to its content and
  overflowed; it now claims the available height.
- Play/pause hit target expanded to the drawn 46 pt circle; two reader error strings localized.

## Config / project
- **Release build fails if `jisho-compact.db` is missing** (would otherwise silently ship the mock
  dictionary).
- `workerBaseURL` rejects an empty `WORKER_HOST` (`"https://"` has no host).
- First-chapter `ContentKey` cache hoisted to `AppServices` (survives route switches).
- `import struct ReaderCore.Document` disambiguates from `SwiftUI.Document` (iOS 26+ SDK).

## Testing
- `scripts/uitest/` — reusable idb driver + screenshot smoke test (library → render → remote TTS +
  highlight → tap-to-define → themes → orientation), including the Xcode-26+/27 SimulatorKit shim.

## Still open (deliberately)
- **L8** (test fixtures bundled into Release) and **L9** (commit the app-target `Package.resolved`) —
  low-value build-config items, worth doing before a real TestFlight.
- Verification gaps that need content the harness can't synthesize: chapter-switch (multi-chapter
  EPUB), scanned-PDF OCR, background-audio lifecycle. Code is in and reviewed; not screenshot-verified.
  See `scripts/uitest/README.md`.
