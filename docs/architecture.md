# Architecture

## Module Split

```
WledCastApp (executable)          WledCore (library)
─────────────────────────         ─────────────────────────
WledCastApp.swift    @main         App/        SessionController, Log, FileLog,
AppDelegate.swift                               LogPaths, PerfLog, AgentControl
AppModel.swift        orchestrator  Capture/    DisplayFrameSource, VideoFrameSource,
MenuBarContent.swift                            VideoAudioPlayer, YouTubeDownloader
Settings/SettingsPaneView.swift   Discovery/  WLEDDiscoveryClient, WLEDInfo
                                  Domain/     Models, VideoSettings
                                  Pipeline/   FramePipeline, RGBFrame, TemporalSmoother
                                  Transport/  DDPSender, DDPPacketizer
                                  UI/Overlay/ OverlayWindowController, CaptureBoxScreen

WledCastCtl (executable)
─────────────────────────
main.swift            CLI → AgentControlClient → control.sock
```

WledCastApp is a thin SwiftUI shell. All capture, processing, transport, and discovery logic lives in WledCore.

## Entry Points

### `@main WledCastApp`

```swift
WledCastApp
  ├── @StateObject AppModel()
  ├── @NSApplicationDelegateAdaptor AppDelegate
  └── MenuBarExtra → MenuBarContent (320px popover)
```

### `AppDelegate.applicationDidFinishLaunching`

Sets `NSApp.setActivationPolicy(.regular)` so the app can show windows and request permissions.

### `AppModel.init()`

Boot sequence:

1. `restore()` — load UserDefaults
2. `migrateLegacyVideoSettings()` — move crop/loop from UserDefaults to file store
3. `refreshVideoLibrary()` — scan `Videos/` for `.mp4`
4. `applyVideoSettings(for:)` — load per-video crop/loop
5. `startDiscovery()` — Bonjour browser + host stream
6. `refreshSelectedHostProfile()` — if saved host exists
7. `Task { verify saved host → autoStart() }`
8. `AgentControlServer.shared.start { handleAgent }`

### `autoStart()`

If not streaming and `canStartStreaming` → `startStreaming()`. Does not auto-show the overlay.

## Runtime Object Graph

```
AppModel
├── WLEDDiscoveryClient (actor)
├── SessionController?          ← created on startStreaming
├── DDPSender?                  ← created on startStreaming
├── DisplayFrameSource?         ← region mode only
├── VideoFrameSource?           ← video mode, streaming
├── VideoFrameSource?           ← video mode, preview-only (not streaming)
├── VideoAudioPlayer?           ← video mode only
├── OverlayWindowController?
├── CaptureBoxRef?              ← thread-safe capture box for region mode
├── VideoSettingsStore
├── YouTubeDownloader (actor)
├── PreviewGate ×2 (mosaic + video HUD throttling)
└── AgentControlServer (singleton, started in init)
```

## Stream Lifecycle

### Start (`startStreaming`)

```
guard !isStreaming, selectedHost, outputResolution
syncFpsFromSelectedHost()
region mode → ensureScreenPermission()

DDPSender(host) + onStateChanged
SessionController(sender, resolution, filters, flickerFighter)
  shouldProcessPreview → mosaicPreviewGate
  onFrameProcessed → updatePreview (mosaic CGImage, gated)
  PerfLog.configure + stream_start event

switch captureMode:
  .video → VideoAudioPlayer + VideoFrameSource
           onFrameBGRA → session.process(bgra:)
  .region → DisplayFrameSource
           onFrameBGRA → session.process(bgra:)

isStreaming = true
```

### Stop (`stopStreaming`)

```
if isStreaming { PerfLog.event("stream_stop") }
session.blackout()           → send zero RGB to WLED
source?.stop()               → region capture
videoSource?.stop()          → video decode
audioPlayer?.stop()
session?.stop()
sender?.stop()
clear mosaic preview
refreshVideoPreviewIfNeeded()
```

### Restart (`restartStreaming`)

`stopStreaming()` then `startStreaming()`. Triggered by:

- Resolution or FPS change while streaming (host switch with same profile does not restart)
- Capture mode switch
- Selected video change (video mode)
- Display change during region capture
- Loop video toggle
- Manual host switch when the new host is not yet in the verified list

## Threading Model

| Component | Queue/Actor |
|-----------|-------------|
| AppModel | `@MainActor` |
| WLEDDiscoveryClient | `actor` |
| DisplayFrameSource output | `wledcast.capture.output` (userInteractive) |
| VideoFrameSource timer | `wledcast.video.source` (userInteractive) |
| DDPSender | `wledcast.ddp.sender` |
| SessionController | called from capture queues; filter lock for config |
| OverlayWindowController | main thread (AppKit/SwiftUI) |

## External Tools (not bundled)

| Tool | Script | Purpose |
|------|--------|---------|
| yt-dlp | `Scripts/fetch_video.sh` | YouTube download |
| ffmpeg | `Scripts/fetch_video.sh` | Transcode to ≤90MB MP4 |
| ffprobe | `Scripts/fetch_video.sh` | Duration for bitrate calc |
| fswatch | `Scripts/dev_watch.sh` | Dev rebuild loop |
| jq | `Scripts/agent_profile.sh` | Profile report aggregation |
| wledcast-ctl | `Scripts/agent_profile.sh`, `Scripts/perf_read.sh` | Agent control + perf reads |

## Permissions

| Permission | When | Mechanism |
|------------|------|-----------|
| Screen Recording | Region mode stream start | `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` |
| Local Network | Bonjour + HTTP + UDP | Info.plist + entitlements |
| Bonjour | Discovery | `_wled._tcp`, `_http._tcp` in Info.plist |

Packaged app bundle ID: `io.wledcast.native`. Entitlements: `network.client` only.
