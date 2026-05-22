# WledCast Documentation

Native macOS menu-bar app that captures screen regions or local MP4 video, processes frames, and streams RGB pixels to WLED LED matrices over DDP (UDP port 4048).

## Index

| Document | Contents |
|----------|----------|
| [Architecture](architecture.md) | Modules, entry points, boot sequence, stream lifecycle |
| [Frame Pipeline](frames.md) | Capture → process → DDP, region and video modes |
| [Audio Pipeline](audio.md) | Local playback, sync with video frames |
| [UI & State](ui.md) | SwiftUI views, overlay, AppModel wiring |
| [Schema](schema.md) | Domain types, wire formats, API contracts |
| [Persistence](persistence.md) | UserDefaults, video settings file, paths |
| [Network](network.md) | Bonjour discovery, WLED HTTP, DDP transport |
| [Agent Control](agent.md) | `wledcast-ctl`, perf logging, `agent.json` |
| [Source Map](source-map.md) | File-by-file reference |

## Quick Path Summary

```
MenuBar / Overlay UI
        │
        ▼
    AppModel (@MainActor)
        │
        ├── WLEDDiscoveryClient → HTTP /json/info, /cfg.json
        │
        ├── DisplayFrameSource (region) ──┐
        │   ScreenCaptureKit              │
        │                                 ├──► SessionController.process(bgra:)
        ├── VideoFrameSource (video) ─────┤         │
        │   AVAssetReader                 │         ├── FramePipeline (scale, color, sharpen)
        │   + VideoAudioPlayer (clock)    │         ├── TemporalSmoother (flicker fighter)
        │                                 │         ├── onFrameProcessed → mosaic preview
        │                                 │         └── DDPSender → DDPPacketizer → UDP :4048
        │
        └── OverlayWindowController (capture box, crop, preview)
```

## Build Targets

| Target | Type | Path |
|--------|------|------|
| WledCore | library | `Sources/WledCore` |
| wledcast-swift | executable | `Sources/WledCastApp` |
| wledcast-ctl | executable | `Sources/WledCastCtl` |
| WledCoreTests | test | `Tests/WledCoreTests` |

Platform: macOS 14+, Swift 5.10+. No third-party SPM dependencies.

Agent control and perf snapshots: see [Agent Control](agent.md).
