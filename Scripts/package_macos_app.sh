#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="WledCast.app"
BIN_NAME="wledcast-swift"
APP_DIR="$DIST_DIR/$APP_NAME"
BUNDLE_ID="io.wledcast.native"
ENTITLEMENTS_PATH="$ROOT_DIR/Resources/WledCast.entitlements"
ICON_PATH="$ROOT_DIR/Resources/WledCast.icns"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swift build -c release --package-path "$ROOT_DIR"
cp "$BUILD_DIR/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"
cp -R "$ROOT_DIR/Scripts" "$APP_DIR/Contents/Resources/Scripts"
if [[ -f "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$APP_DIR/Contents/Resources/WledCast.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>WledCast</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER:-1}</string>
    <key>CFBundleIconFile</key>
    <string>WledCast.icns</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>WledCast captures a region of your screen and streams it to WLED devices.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>WledCast uses system events for window selection.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>WledCast discovers WLED matrices on your local network and streams pixels to them.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_wled._tcp</string>
        <string>_http._tcp</string>
    </array>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${CODESIGN_IDENTITY:-641C0FEB1D09ABCEF789F46E3A2761975DB4A869}"
codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGN_IDENTITY" "$APP_DIR"

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

mkdir -p "$DIST_DIR"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$DIST_DIR/WledCast-macos.zip"

echo ""
echo "Built and signed: $APP_DIR"
echo "Bundle ID: $BUNDLE_ID"
echo "Signing identity: $SIGN_IDENTITY"
echo ""
echo "Then launch with:"
echo "  open \"$APP_DIR\""
