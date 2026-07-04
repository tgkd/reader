#!/bin/sh
# Xcode Cloud resolves ci_scripts either at the repo root or beside the Xcode
# project depending on configuration — this delegate covers the root location.
# The real script lives next to the project: app/ci_scripts/ci_post_clone.sh.
exec "$(dirname "$0")/../app/ci_scripts/ci_post_clone.sh"
