#!/bin/sh
# Xcode Cloud post-clone setup. A clean checkout lacks four gitignored pieces:
#  1. Reader.xcodeproj — xcodegen owns it; generate it here.
#  2. Reader/Resources/jisho-compact.db (43MB) — fetched from the public
#     "compact-dict" GitHub release on tgkd/reader (refresh: regenerate with
#     scripts/build-compact-dict.sh, then `gh release upload compact-dict
#     app/Reader/Resources/jisho-compact.db --clobber -R tgkd/reader`).
#  3. Signing.xcconfig — generated from Xcode Cloud env vars (READER_TEAM_ID,
#     READER_REVENUECAT_KEY; optional READER_WORKER_HOST — blank falls back to
#     the production Worker baked into the app).
#  4. Package.resolved — Xcode Cloud disables automatic SPM resolution; a
#     tracked copy (app/Package.resolved) is placed into the generated project.
set -e

REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
APP_DIR="$REPO_ROOT/app"

DB_FILE="$APP_DIR/Reader/Resources/jisho-compact.db"
if [ ! -f "$DB_FILE" ]; then
    mkdir -p "$(dirname "$DB_FILE")"
    echo "Downloading jisho-compact.db..."
    curl -SfL --retry 3 -o "$DB_FILE" \
        "https://github.com/tgkd/reader/releases/download/compact-dict/jisho-compact.db"
    ls -lh "$DB_FILE"
fi

if [ ! -f "$APP_DIR/Signing.xcconfig" ]; then
    cat > "$APP_DIR/Signing.xcconfig" <<EOF
DEVELOPMENT_TEAM = ${READER_TEAM_ID:-}
WORKER_HOST = ${READER_WORKER_HOST:-}
REVENUECAT_KEY = ${READER_REVENUECAT_KEY:-}
EOF
fi

brew install xcodegen
cd "$APP_DIR"
xcodegen generate

SWIFTPM_DIR="Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$SWIFTPM_DIR"
cp Package.resolved "$SWIFTPM_DIR/Package.resolved"
