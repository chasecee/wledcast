# UI & State

How SwiftUI views connect to `AppModel` and core subsystems.

## View Hierarchy

```
WledCastApp (@main)
├── MenuBarExtra (320px)
│   └── MenuBarContent
│       └── @EnvironmentObject AppModel
│
└── AppModel creates:
    └── OverlayWindowController (NSWindow)
        └── UnifiedOverlayRoot (SwiftUI)
            ├── OverlayHUD (top region)
            │   ├── Region mode: capture box overlay on screen
            │   ├── Video mode: preview + crop handles
            │   └── Mosaic preview (optional)
            └── SettingsPaneView (bottom region, embedded)
                └── @EnvironmentObject AppModel
```

## Menu Bar (`MenuBarContent.swift`)

| UI Action | AppModel Method | Side Effects |
|-----------|-----------------|--------------|
| Status line | read-only | `isStreaming`, `selectedHost`, `senderState`, `wledFpsLabel` |
| Host list item | `setHost(_:)` | Apply profile, persist, restart/auto-start |
| Start/Stop Stream | `startStreaming()` / `stopStreaming()` | Full pipeline lifecycle |
| Show/Hide Window | `toggleOverlay()` | Overlay show/hide, preview start/stop |
| Quit | `quit()` | `stopStreaming()`, `NSApp.terminate` |

Icon: `dot.radiowaves.left.and.right` when streaming, `square.dashed` when idle.

## Settings Pane (`SettingsPaneView.swift`)

Responsive grid: 1 column (<500px), 2 columns (500–760px), 3 columns (≥760px).

Height reported via `PreferenceKey` → `overlay.setSettingsHeight`.

### Capture & Output Section

| Control | Binding | AppModel Path |
|---------|---------|---------------|
| Mode picker (Region/Video) | `setCaptureMode(_:)` | Restart stream, refresh library, overlay mode |
| WLED host picker | `setHost(_:)` | Profile apply, persist |
| Start/Stop button | `startStreaming()` / `stopStreaming()` | |
| Frame rate label | read-only | `wledFpsLabel` from WLED profile |
| Aspect lock toggle | `setAspectLock(_:)` | `overlay.aspectLock`, persist |
| Mosaic preview toggle | `setOverlayMosaicEnabled(_:)` | `overlay.mosaicHolder`, persist |

### Video Source Section (video mode only)

| Control | Binding | AppModel Path |
|---------|---------|---------------|
| YouTube URL field | `youtubeURLInput` | |
| Fetch button | `fetchYouTube()` | `YouTubeDownloader` → `Scripts/fetch_video.sh` |
| Fetch state | `fetchState` | idle / running / failed |
| Video library picker | `setSelectedVideo(_:)` | Load video settings, restart if streaming |
| Loop toggle | `setLoopVideo(_:)` | Restart stream or refresh preview |
| Volume slider | `setAudioVolume(_:)` | `audioPlayer.setVolume`, persist |
| Mute toggle | `setAudioMuted(_:)` | Audio/video sync path, persist |
| Loop range slider | `beginLoopScrub()` / `scrubLoopRange()` / `commitLoopRange()` | AVAssetImageGenerator thumbnails |

### Filters Section

| Control | Binding | AppModel Path |
|---------|---------|---------------|
| Saturation | `setFilters(_:)` | `session.updateFilters`, persist |
| Brightness | same | |
| Contrast | same | |
| Sharpen | same | |
| Balance R/G/B | same | |
| Flicker fighter | `setFlickerFighter(_:)` | `session.updateFlickerFighter`, persist |

## Overlay (`OverlayWindowController.swift`)

Floating `NSWindow` with two regions: top (HUD/preview) and bottom (settings).

### Region Mode Interactions

| Interaction | Handler | Data Flow |
|-------------|---------|-----------|
| Drag ring (move) | `startDrag` / `move` | Updates `captureBox` left/top on display |
| 8 resize handles | `startResize` / `resize(handle:)` | Updates captureBox width/height |
| Arrow keys | key monitor | Nudge box 1px (Shift: 10px) |
| `onChange` callback | → AppModel | `captureBox` persist, `source.updateRegion` or restart |

Capture box is stored in screen coordinates (`CaptureBox`), not window frame. Red border drawn in overlay HUD represents the region being captured.

Aspect lock: resize constrained to WLED output aspect ratio when enabled.

### Video Mode Interactions

| Interaction | Handler | Data Flow |
|-------------|---------|-----------|
| 8 crop handles | crop drag/resize | `videoCropBox` normalized 0–1 |
| Window edge resize | `enforceVideoAspectOnTopRegion` | Maintains video aspect |
| `onVideoCropChange` | → AppModel | `videoSource.updateCrop`, `VideoSettingsStore.save` |

### Preview Display

| Source | Method | When |
|--------|--------|------|
| Processed RGB | `mosaicHolder.set(CGImage)` | Streaming + mosaic on + overlay visible + gate |
| Raw pixel buffer | `setPreviewBuffer(CVPixelBuffer)` | Video mode + overlay visible + gate |
| Scrub thumbnail | `setPreviewImage(NSImage)` | Loop range scrubbing |

### Preview Throttling (`PreviewGate`)

Two gates in `AppModel`: `mosaicPreviewGate` and `videoPreviewGate`.

| Gate | Enabled when | Controls |
|------|--------------|----------|
| Mosaic | `overlayMosaicEnabled && isOverlayVisible` | `SessionController.shouldProcessPreview` |
| Video HUD | `isOverlayVisible` | `VideoFrameSource.shouldEmitPreview` |

Interval: `1/fps`, minimum 1/120s. Previews emit at most once per interval even if capture runs faster.

### Overlay Exclusion from Capture

```
overlay.captureWindowID → CGWindowID
DisplayFrameSource excludedWindowIDs: [captureWindowID]
```

Prevents the red capture box from appearing in the captured stream.

## AppModel Published State

All UI reads from these `@Published` properties:

| Property | Type | Source |
|----------|------|--------|
| `hosts` | `[WLEDHost]` | Discovery stream |
| `selectedHost` | `String` | User + discovery |
| `outputResolution` | `OutputResolution?` | WLED profile |
| `fps` / `targetFps` | `Int` | WLED profile |
| `filters` | `FilterConfig` | User + persist |
| `flickerFighter` | `Double` | User + persist |
| `captureBox` | `CaptureBox` | Overlay + persist |
| `captureMode` | `CaptureMode` | User + persist |
| `videoLibrary` | `[URL]` | Videos/ scan |
| `selectedVideo` | `URL?` | User + persist |
| `youtubeURLInput` | `String` | User input |
| `fetchState` | `FetchState` | YouTube fetch |
| `videoCropBox` | `VideoCropBox` | VideoSettingsStore |
| `loopVideo` | `Bool` | User + persist |
| `loopRange` | `LoopRange` | VideoSettingsStore |
| `overlayMosaicEnabled` | `Bool` | User + persist |
| `aspectLock` | `Bool` | User + persist |
| `isStreaming` | `Bool` | Stream lifecycle |
| `senderState` | `DDPSenderState` | DDPSender callback |
| `audioVolume` | `Double` | User + persist |
| `audioMuted` | `Bool` | User + persist |

## UI → Core Callback Map

```
Settings/MenuBar user action
        │
        ▼
   AppModel method
        │
        ├── persist() → UserDefaults
        ├── videoSettingsStore.save() → JSON file
        ├── session?.updateFilters / updateFlickerFighter
        ├── source?.updateRegion / videoSource?.updateCrop
        ├── audioPlayer?.setVolume / setMuted / syncTo
        ├── overlay?.setMode / setVideoCrop / mosaicHolder
        ├── discovery (indirect via setHost)
        ├── PerfLog.syncSession (overlay/mosaic changes)
        └── startStreaming / stopStreaming / restartStreaming
                │
                ├── DDPSender
                ├── SessionController
                ├── DisplayFrameSource | VideoFrameSource
                └── VideoAudioPlayer
```

## Host Selection Logic

```
Discovery stream update:
  hosts empty + selectedHost empty → no-op
  selectedHost empty → select first discovered host
  selectedHost in discovered → apply updated profile
  selectedHost NOT in discovered → reconcileSelectedHostIfNeeded()
    1. HTTP probe saved host directly
    2. If unreachable: replace if single host or single resolution match
```

Saved host verified once per session via `savedHostReachabilityChecked` flag.

## canStartStreaming

```
selectedHost non-empty
outputResolution != nil
if video mode: selectedVideo != nil
region mode: no extra requirement (permission checked at start)
```

Auto-start runs on launch when conditions met. Does not auto-show the overlay.
