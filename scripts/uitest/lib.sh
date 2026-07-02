#!/usr/bin/env bash
# Reusable idb driver for the Yomi simulator UI tests.
#
# Sourced by the test scripts in this directory. Provides tap/swipe/screenshot and
# accessibility-tree helpers against the booted iOS simulator via Facebook's idb.
#
# One-time setup (see README.md):
#   brew install facebook/fb/idb-companion
#   pipx install --python python3.11 fb-idb      # fb-idb needs Python <=3.12
#
# Xcode 26 stable works out of the box. Xcode 26+/27 beta moved SimulatorKit into
# Contents/SharedFrameworks, so the (2022) companion can't do HID taps — this script
# builds a DEVELOPER_DIR "shim" that symlinks SimulatorKit back where idb expects it.

set -uo pipefail

export PATH="$HOME/.local/bin:$PATH"          # pipx installs idb here
: "${IDB_PORT:=10882}"
: "${SHOT_DIR:=/tmp/yomi-uitest}"
mkdir -p "$SHOT_DIR"

# --- Xcode / simulator discovery -------------------------------------------------

# Full Xcode (with a Developer dir), NOT CommandLineTools. Override with XCODE_APP.
_find_xcode() {
  if [[ -n "${XCODE_APP:-}" && -d "$XCODE_APP/Contents/Developer" ]]; then echo "$XCODE_APP"; return; fi
  for app in /Applications/Xcode.app /Applications/Xcode-*.app; do
    [[ -d "$app/Contents/Developer" ]] && { echo "$app"; return; }
  done
}
XCODE_APP="$(_find_xcode)"
[[ -z "$XCODE_APP" ]] && { echo "ERROR: no full Xcode found (set XCODE_APP)"; return 1 2>/dev/null || exit 1; }
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"   # for simctl / xcodebuild

# The booted simulator's UDID (override with UDID=...).
: "${UDID:=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '[0-9A-F-]{36}' | head -1)}"
[[ -z "$UDID" ]] && { echo "ERROR: no booted simulator (boot one in Simulator.app)"; return 1 2>/dev/null || exit 1; }

# DEVELOPER_DIR the idb COMPANION uses. If SimulatorKit isn't where the companion
# looks, build a symlink-farm shim that mirrors Xcode + adds it.
_companion_devdir() {
  local dev="$XCODE_APP/Contents/Developer"
  if [[ -d "$dev/Library/PrivateFrameworks/SimulatorKit.framework" ]]; then echo "$dev"; return; fi
  local shared="$XCODE_APP/Contents/SharedFrameworks/SimulatorKit.framework"
  [[ ! -d "$shared" ]] && { echo "$dev"; return; }   # nothing we can do; try as-is
  local shim="$HOME/.cache/idb-xcode-shim"
  if [[ ! -e "$shim/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework" ]]; then
    rm -rf "$shim"; mkdir -p "$shim/Contents/Developer/Library/PrivateFrameworks"
    local it n
    for it in "$XCODE_APP/Contents"/*;          do n=$(basename "$it"); [[ "$n" == Developer ]] && continue; ln -s "$it" "$shim/Contents/$n"; done
    for it in "$dev"/*;                          do n=$(basename "$it"); [[ "$n" == Library ]] && continue;   ln -s "$it" "$shim/Contents/Developer/$n"; done
    for it in "$dev/Library"/*;                  do n=$(basename "$it"); [[ "$n" == PrivateFrameworks ]] && continue; ln -s "$it" "$shim/Contents/Developer/Library/$n"; done
    ln -s "$shared" "$shim/Contents/Developer/Library/PrivateFrameworks/SimulatorKit.framework"
  fi
  echo "$shim/Contents/Developer"
}

# --- Companion lifecycle ---------------------------------------------------------

idb_up() {
  if ! pgrep -f "idb_companion.*$UDID" >/dev/null; then
    DEVELOPER_DIR="$(_companion_devdir)" nohup idb_companion --udid "$UDID" --grpc-port "$IDB_PORT" \
      >"$SHOT_DIR/idb_companion.log" 2>&1 &
    sleep 5
  fi
  idb connect localhost "$IDB_PORT" >/dev/null 2>&1
  pgrep -f "idb_companion.*$UDID" >/dev/null || { echo "ERROR: companion failed — see $SHOT_DIR/idb_companion.log"; return 1; }
}
idb_down() { pkill -f "idb_companion.*$UDID" 2>/dev/null; }

# --- App lifecycle ---------------------------------------------------------------

# Install a built .app IN PLACE (no uninstall) so StoreKit/RevenueCat state survives.
app_install() { xcrun simctl install "$UDID" "$1"; }
app_launch()  { xcrun simctl launch "$UDID" "${1:-app.reader.app}" >/dev/null; }
app_relaunch(){ local b="${1:-app.reader.app}"; xcrun simctl terminate "$UDID" "$b" 2>/dev/null; app_launch "$b"; }

# --- Interaction primitives (device points) --------------------------------------

tap()   { idb ui tap   --udid "$UDID" "$1" "$2" 2>/dev/null; }
swipe() { idb ui swipe --udid "$UDID" "$1" "$2" "$3" "$4" 2>/dev/null; }
shot()  { idb screenshot --udid "$UDID" "$SHOT_DIR/$1" 2>/dev/null && echo "  📸 $SHOT_DIR/$1"; }

# Accessibility tree as "TYPE 'label' @ (cx,cy)" lines (cx,cy = tap center in points).
tree() {
  idb ui describe-all --udid "$UDID" 2>/dev/null | python3 -c "
import sys, json
for el in json.load(sys.stdin):
    l = el.get('AXLabel') or ''; f = el.get('frame', {}); t = el.get('type','')
    if l and f: print(f\"{t} '{l}' @ ({int(f['x']+f['width']/2)},{int(f['y']+f['height']/2)})\")
"
}

# Tap the first element whose accessibility label CONTAINS \$1 (substring, robust to
# coordinates changing between OS/screen sizes). Returns 1 if not found.
tap_label() {
  local coords
  coords=$(tree | grep -F "'$1" | head -1 | grep -oE '\([0-9]+,[0-9]+\)$' | tr -d '()')
  [[ -z "$coords" ]] && { echo "  ✗ label not found: $1"; return 1; }
  tap "${coords%,*}" "${coords#*,}"
}

# Poll the a11y tree until a label appears (timeout $2 seconds, default 30).
wait_for_label() {
  local want="$1" secs="${2:-30}" i
  for ((i=0; i<secs; i++)); do
    tree | grep -qF "'$want" && return 0
    sleep 1
  done
  return 1
}
