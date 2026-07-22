#!/usr/bin/env bash
# Yomi end-to-end smoke test against a booted simulator.
#
# Drives the main features and drops annotated screenshots into $SHOT_DIR so you can
# eyeball the result. Meant to be run against a build installed from Xcode with the
# StoreKit config active (so a subscription is available for the TTS path).
#
#   ./scripts/uitest/smoke.sh                 # full walkthrough
#   BOOK="こころ" ./scripts/uitest/smoke.sh   # target a specific (uncached) book
#
# It does NOT reinstall the app — run/​install it yourself first (Cmd-R in Xcode, or
# `scripts/uitest/install.sh`) so the live subscription/library are preserved.
#
# Each step prints PASS/CHECK. "CHECK" means "look at the screenshot" — rendering
# correctness (furigana, themes, the moving highlight) can't be asserted from the
# a11y tree, only seen. The screenshots are the artifact.

cd "$(dirname "$0")"
source ./lib.sh

: "${BOOK:=こころ}"        # prefer an UNCACHED book to exercise remote synthesis
: "${WORD:=先生}"          # a word to tap for tap-to-define (must be visible on open)

idb_up || exit 1
echo "▶ Yomi smoke test — UDID=$UDID  shots→$SHOT_DIR"

pass(){ echo "  ✅ $*"; }
check(){ echo "  🔎 CHECK: $*"; }

# 1. Library -----------------------------------------------------------------------
echo "[1] Library"
app_relaunch
sleep 3
shot 01-library.png
tree | grep -q "'$BOOK" && pass "library lists '$BOOK'" || echo "  ✗ '$BOOK' not in library"
check "01-library.png — rows, authors, progress bars, cached (↓) badges"

# 2. Reader rendering --------------------------------------------------------------
echo "[2] Reader — open '$BOOK'"
tap_label "$BOOK"; sleep 2
shot 02-reader.png
check "02-reader.png — vertical text, furigana above kanji, paragraphs/indents"

# 3. Remote TTS synthesis + transport ---------------------------------------------
echo "[3] TTS — synthesize + play"
tap_label "Expand player"; sleep 1   # collapsed circle → capsule
tap_label "Play"; sleep 1            # pre-audio row Play (or ready-row Play on a cache hit)
if wait_for_label "Playback position" 90; then
  pass "synthesis completed, transport appeared"
else
  echo "  ✗ no transport after 90s — synthesis/Worker/subscription problem"
fi
sleep 1; shot 03a-playing.png
check "03a-playing.png — moving highlight on the active token, scrubber advancing"
sleep 2; shot 03b-playing.png
check "03b-playing.png — highlight advanced vs 03a (word-sync working)"

# 4. Tap-to-define -----------------------------------------------------------------
echo "[4] Tap-to-define — tap '$WORD'"
# The reading surface is one a11y element, so tap by coordinate. Adjust WORD_XY for
# your text/first line if needed (device points on iPhone 17 Pro).
: "${WORD_XY:=338 490}"
tap $WORD_XY; sleep 2
shot 04-define.png
if tree | grep -q "Play pronunciation"; then
  pass "definition sheet opened"
  tap_label "Play pronunciation"; sleep 1; pass "pronounce tapped (no crash)"
else
  echo "  ✗ no definition sheet — adjust WORD_XY to hit a word"
fi
check "04-define.png — headword, reading, senses, example sentence"
swipe 201 980 201 1700; sleep 1   # dismiss sheet

# 5. Themes ------------------------------------------------------------------------
echo "[5] Themes — cycle paper → white → sepia → night"
tap_label "Theme"; sleep 1; shot 05a-theme.png
tap_label "Theme"; sleep 1; shot 05b-theme.png
tap_label "Theme"; sleep 1; shot 05c-theme.png
check "05a/05b/05c — ALL text legible in every theme (night = light text on dark, not black-on-black)"

# 6. Orientation -------------------------------------------------------------------
echo "[6] Orientation — toggle tategaki/yokogaki"
tap_label "Toggle writing direction"; sleep 1; shot 06-orientation.png
check "06-orientation.png — layout flipped, furigana + highlight still correct"

echo "▶ done. Review screenshots in $SHOT_DIR"
