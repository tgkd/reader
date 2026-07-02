#!/usr/bin/env bash
# Build the app and install it on the booted simulator IN PLACE (no uninstall), so a
# StoreKit-test subscription and the existing library survive. Use this instead of
# `simctl uninstall && install` when you've already activated a subscription.
#
# NOTE: installing a command-line build does NOT activate the .storekit config the
# way `Cmd-R` from Xcode does. For the TTS/subscription path, prefer running once
# from Xcode; this script is for iterating on a build that's already entitled.

cd "$(dirname "$0")"
source ./lib.sh

APP_DIR="$(cd ../../app && pwd)"
DERIVED="$APP_DIR/build"

echo "▶ building Reader ($XCODE_APP)…"
xcodebuild -project "$APP_DIR/Reader.xcodeproj" -scheme Reader \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" build \
  2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -5

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Reader.app"
[[ -d "$APP" ]] || { echo "ERROR: build product missing at $APP"; exit 1; }

echo "▶ installing in place…"
app_install "$APP" && echo "  ✅ installed (subscription/library preserved)"
app_relaunch && echo "  ✅ relaunched"
