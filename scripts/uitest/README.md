# Yomi simulator UI tests

Screenshot-driven smoke tests for the app running on a booted iOS simulator, driven
by [idb](https://fbidb.io) (Facebook's iOS Development Bridge). These exercise the
things unit tests can't: real CoreText rendering, furigana, themes, the word-synced
highlight, and the live TTS / OCR (remote-parsing) paths.

They drive the **already-installed** app so a StoreKit-test subscription and the
current library are preserved (no uninstall). Rendering correctness is verified by
eyeballing the screenshots the scripts drop in `$SHOT_DIR` (default `/tmp/yomi-uitest`).

## One-time setup

```bash
# 1. idb companion (talks to CoreSimulator) + Python client (fb-idb needs Python ≤3.12)
brew install facebook/fb/idb-companion
pipx install --python "$(brew --prefix)/bin/python3.11" fb-idb   # → ~/.local/bin/idb

# 2. Boot a simulator and run the app once from Xcode (Cmd-R) so the StoreKit config
#    is active, then activate a subscription via the paywall (needed for TTS/OCR).
```

### Xcode 26+ / 27 note (SimulatorKit)

Newer Xcode moved `SimulatorKit.framework` into `Contents/SharedFrameworks`, where the
(2022) idb companion can't find it — a11y reads work but **taps fail** with
`SimulatorKit is required for HID interactions`. `lib.sh` handles this automatically:
it builds a symlink-farm `DEVELOPER_DIR` shim under `~/.cache/idb-xcode-shim` that puts
SimulatorKit back where the companion looks. Nothing to do manually; just know why the
shim exists. (The Xcode.app bundle itself is SIP-protected, so it can't be patched in
place.)

## Running

```bash
scripts/uitest/install.sh          # build + install in place (optional; keeps subscription)
scripts/uitest/smoke.sh            # full walkthrough → screenshots in $SHOT_DIR
BOOK="こころ" WORD="先生" scripts/uitest/smoke.sh
open /tmp/yomi-uitest              # review the screenshots
```

Env knobs: `UDID` (default: booted sim), `XCODE_APP`, `SHOT_DIR`, `IDB_PORT`, `BOOK`,
`WORD`, `WORD_XY` (device-point tap for the word, since the reading surface is a single
a11y element).

## Writing your own steps

`source scripts/uitest/lib.sh`, then:

| helper | what it does |
|---|---|
| `idb_up` / `idb_down` | start/stop the companion (builds the Xcode-27 shim if needed) |
| `tree` | print the a11y tree as `TYPE 'label' @ (cx,cy)` (cx,cy = tap center, points) |
| `tap_label "Play"` | tap the first element whose label contains the string (coordinate-free) |
| `tap X Y` / `swipe x1 y1 x2 y2` | raw gestures in device points |
| `wait_for_label "Playback position" 90` | poll until a label appears (synthesis, OCR) |
| `shot name.png` | screenshot into `$SHOT_DIR` |
| `app_install DIR.app` / `app_relaunch` | in-place install / relaunch (no uninstall) |

Prefer `tap_label` over raw coordinates where an a11y label exists — it survives
screen-size and layout changes. The reading surface itself is one static-text element
(intentionally, for VoiceOver), so tapping a specific word needs `tap X Y`.

## Test cases (what `smoke.sh` covers)

Manual checklist mirrored by the script — the ✅ steps assert via the a11y tree, the 🔎
steps need a human/vision look at the screenshot:

1. **Library** — ✅ book rows present · 🔎 authors, progress bars, cached (↓) badges.
2. **Reader rendering** — 🔎 vertical text, furigana above kanji, paragraph breaks + 　indents.
3. **Remote TTS** — ✅ Play → transport appears within timeout (Worker + subscription) ·
   🔎 word-synced highlight advances across two frames (03a vs 03b).
4. **Tap-to-define** — ✅ tapping a word opens the sheet, pronounce doesn't crash ·
   🔎 headword / reading / senses / example.
5. **Themes** — 🔎 paper · sepia · night all render **all** text legibly
   (night regression guard: must be light-on-dark, never black-on-black).
6. **Orientation** — 🔎 tategaki ⇄ yokogaki flip keeps furigana + highlight correct.

Not automated here (need a multi-chapter book / file picker / OCR source):
- **Chapter switch** (open a multi-chapter EPUB, switch chapters, Play → the *new*
  chapter's audio must play, scrubber shows its real duration — regression guard for
  the stale-`AVAudioPlayer` fix).
- **Import** (the `+` file picker and "Open in Yomi" — system UI idb can't drive) and
  **scanned-PDF OCR** (needs a scanned source + the confirm prompt).
- **Background audio** (lock screen → chapter finish still marks 読了; interruption
  pause/resume).
