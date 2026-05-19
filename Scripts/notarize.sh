#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/WledCast.app"
ZIP_PATH="$DIST_DIR/WledCast-macos.zip"
KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-wledcast-notary}"

if [[ ! -f "$ZIP_PATH" ]]; then
  ./Scripts/package_macos_app.sh
fi

xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
