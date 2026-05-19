# WledCast

Native macOS menu-bar app for capturing part of your screen and streaming frames to WLED over DDP.

## Fork credit

This repository is a fork of the original `wledcast` project by [ppamment](https://github.com/ppamment): [github.com/ppamment/wledcast](https://github.com/ppamment/wledcast).

The native Swift/macOS app in this fork builds on that original work.

## Current app

- SwiftUI menu-bar UI with Settings window
- ScreenCaptureKit capture pipeline (region/display/window modes)
- Floating overlay with drag + 8-handle resize
- Live Bonjour discovery with WLED resolution probing
- DDP sender with reconnect/backoff handling
- Signed `.app` packaging script for Developer ID distribution

## Requirements

- macOS 14+
- Swift 5.10+
- A WLED device reachable on your local network

## Development

Build and test:

```shell
swift test
swift build -c release
```

Run from source:

```shell
swift run wledcast-swift
```

Live-reload dev loop (rebuild + relaunch on every Swift save):

```shell
brew install fswatch
./Scripts/dev_watch.sh
```

Run CI checks locally:

```shell
./Scripts/ci_checks.sh
```

## Packaging and signing

Build a signed `.app` bundle and zip:

```shell
./Scripts/package_macos_app.sh
```

Default signing identity:

`Developer ID Application: Chase Christensen (HAGYW94HB9)`

You can override with:

```shell
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/package_macos_app.sh
```

Optional notarization workflow:

```shell
NOTARY_KEYCHAIN_PROFILE=your-profile ./Scripts/notarize.sh
```

## Permissions

The app requires Screen Recording permission to capture frames.

When launched as the packaged `.app`, permissions should remain stable across releases as long as bundle id and signing identity stay constant.

## Legacy Python implementation

The older cross-platform Python implementation was archived under `legacy/`.

- Main package: `legacy/wledcast`
- Python project files: `legacy/pyproject.toml`, `legacy/uv.lock`
- Older parity helper: `legacy/Scripts/generate_parity_fixtures.py`

## License

GPLv3. See `LICENSE`.
