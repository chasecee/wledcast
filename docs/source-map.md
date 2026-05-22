# Source Map

File-by-file reference with responsibilities and connections.

## Package Root

| File | Role |
|------|------|
| `Package.swift` | SPM manifest: WledCore lib, wledcast-swift, wledcast-ctl, WledCoreTests |
| `README.md` | User-facing build/run instructions |
| `build.sh` | Rebuild release + relaunch packaged app |
| `LICENSE` | GPLv3 |

## Scripts/

| File | Role |
|------|------|
| `package_macos_app.sh` | Build `.app` bundle, codesign, zip |
| `notarize.sh` | Apple notarization workflow |
| `ci_checks.sh` | Local CI (test + build) |
| `dev_watch.sh` | fswatch rebuild loop |
| `fetch_video.sh` | yt-dlp + ffmpeg download/transcode |
| `perf_read.sh` | Print agent.json + perf.log tail |
| `agent_profile.sh` | CPU/profile A/B via wledcast-ctl |

## Resources/

| File | Role |
|------|------|
| `WledCast.icns` | App icon |
| `WledCast.entitlements` | Network client entitlement |

---

## Sources/WledCastApp/

### WledCastApp.swift

`@main` entry. Creates `AppModel`, `MenuBarExtra` with streaming icon toggle.

### AppDelegate.swift

Sets activation policy to `.regular` on launch.

### AppModel.swift

Central orchestrator. All UI actions land here.

**Owns:** discovery, session, sender, capture sources, audio, overlay, persistence.

**Key paths:**
- `init()` → restore, discover, autoStart, AgentControlServer
- `startStreaming()` / `stopStreaming()` → pipeline lifecycle + PerfLog events
- `handleAgent(_:)` → headless control (overlay, stream, mosaic, fps)
- `setHost()` / `setCaptureMode()` / filter setters → config + restart
- `fetchYouTube()` → YouTubeDownloader
- Overlay callbacks → captureBox, videoCropBox updates

### MenuBarContent.swift

Menu bar popover: status, host list, stream/window/quit controls.

### Settings/SettingsPaneView.swift

Embedded in overlay bottom pane. Sections:

- `CaptureOutputSection` — mode, host, stream, fps, aspect, mosaic
- `VideoSourceSection` — YouTube, library, loop, audio, loop range
- `FiltersSection` — image processing sliders

---

## Sources/WledCastCtl/

### main.swift

CLI for agent control. Maps subcommands to `AgentControlRequest`, sends via `AgentControlClient`. `perf` reads `LogPaths.agentSnapshot` directly.

---

## Sources/WledCore/App/

### SessionController.swift

Frame processing hub. `process(bgra:)` → pipeline → smoother → optional preview callback + DDP send.

Uses reusable `workPixels` buffer. Preview callback gated by `shouldProcessPreview`. Records timing via `PerfLog.recordFrame`.

### Log.swift

Structured logging channels to os.log + FileLog.

### FileLog.swift

Append-only log file with 1MB trim. Path from `LogPaths.fileLog`.

### LogPaths.swift

Resolves log directory (env override, repo `logs/`, or `~/Library/Logs/WledCast/`). Exposes paths for file log, perf log, agent snapshot, control socket.

### PerfLog.swift

Perf event writer + rolling `agent.json` snapshot with session state and 2s metric windows.

### AgentControl.swift

UNIX socket server (`AgentControlServer`) and client (`AgentControlClient`). JSON newline protocol for headless app control.

---

## Sources/WledCore/Capture/

### CaptureEngine.swift

`CaptureBoxRef` — thread-safe capture box holder.

`DisplayFrameSource` — ScreenCaptureKit region capture.

**Outputs:** `onFrameBGRA`, `onDiagnostics`

**Inputs:** boxRef, outputResolution, fps, captureSelection, excludedWindowIDs

### VideoFrameSource.swift

MP4 decode via AVAssetReader, timer-driven frame selection.

**Outputs:** `onFrameBGRA`, `onPreviewBuffer`

**Inputs:** url, fps, crop, loop, loopRange, decodeTarget, playbackClock

**Gating:** `shouldEmitPreview` controls HUD preview emission rate

### VideoAudioPlayer.swift

Local AVPlayer audio with loop range, rate scaling, cached playback time.

**Consumed by:** VideoFrameSource.playbackClock

### YouTubeDownloader.swift

Actor wrapping `fetch_video.sh`. Parses `saved:` line from stdout.

---

## Sources/WledCore/Discovery/

### WLEDDiscoveryClient.swift

Bonjour browser + HTTP verification actor.

**Outputs:** `AsyncStream<[WLEDHost]>`

**HTTP:** `/json/info`, `/cfg.json`, `/json/cfg`

### WLEDInfo.swift

JSON parsers for WLED info and config responses.

---

## Sources/WledCore/Domain/

### Models.swift

All shared value types: CaptureBox, OutputResolution, FilterConfig, CaptureMode, VideoCropBox, LoopRange, WLEDHost, etc.

### VideoSettings.swift

VideoSettings struct, VideoKey derivation, VideoSettingsStore file persistence.

---

## Sources/WledCore/Pipeline/

### FramePipeline.swift

vImage scale BGRA→RGB, color filters, sharpen.

### RGBFrame.swift

Output pixel buffer struct.

### TemporalSmoother.swift

Deadband + blend temporal noise reduction (flicker fighter).

---

## Sources/WledCore/Transport/

### DDPSender.swift

UDP NWConnection, reconnect with 1.2s backoff, blackout support.

### DDPPacketizer.swift

DDP header framing, 1200-byte chunking, sequence 0–15.

---

## Sources/WledCore/UI/Overlay/

### OverlayWindowController.swift

Floating window: region capture box UI, video crop UI, mosaic/preview display, settings embedding.

**Callbacks:** onChange (CaptureBox), onVideoCropChange (VideoCropBox)

**Key types:** MosaicLayerView, MosaicImageHolder, UnifiedOverlayRoot, OverlayHUD

### CaptureBoxScreen.swift

NSScreen extension: `screen(for: displayID)`, CaptureBox.centered helper.

---

## Tests/WledCoreTests/

| File | Covers |
|------|--------|
| `DDPPacketizerTests.swift` | Packet framing vs fixture |
| `FilterPipelineTests.swift` | FramePipeline color processing |
| `TemporalSmootherTests.swift` | Flicker reduction math |
| `WLEDInfoParserTests.swift` | Info JSON parsing |
| `WLEDCfgParserTests.swift` | Config FPS parsing |
| `VideoSettingsStoreTests.swift` | File persistence |
| `YouTubeDownloaderTests.swift` | Saved path parsing |
| `MosaicPlacementTests.swift` | Mosaic rect layout |
| `WindowLayoutTests.swift` | Overlay window frame math |
| `FixtureLoader.swift` | Test fixture helper |
| `Fixtures/ddp_fixture.json` | DDP expected packets |
| `Fixtures/wled_info_fixtures.json` | WLED info parse cases |

---

## Dependency Graph (imports)

```
WledCastApp
  → SwiftUI, AppKit, AVFoundation, WledCore

WledCore/App
  → Accelerate, Foundation

WledCore/Capture
  → ScreenCaptureKit, AVFoundation, Accelerate, AppKit

WledCore/Discovery
  → Foundation, Network

WledCore/Pipeline
  → Accelerate, Foundation

WledCore/Transport
  → Foundation, Network

WledCore/UI/Overlay
  → AppKit, SwiftUI, CoreImage, CoreVideo, VideoToolbox
```

No cross-imports between WledCore submodules beyond shared Domain types.

---

## Complete Call Graph: One Frame (Region Mode)

```
SCStream output queue
  DisplayFrameSource.consume(sampleBuffer)
    onFrameBGRA(vImage_Buffer)
      SessionController.process(bgra:)
        FramePipeline.process(rgbOut:) → workPixels
        TemporalSmoother.apply(pixels:)
        PerfLog.recordFrame
        onFrameProcessed?(pixels) [if shouldProcessPreview]
          AppModel.updatePreview → CGImage → mosaicHolder
        DDPSender.send(pixels:)
          DDPPacketizer.packets → NWConnection.send × N
```

## Complete Call Graph: One Frame (Video Mode)

```
VideoFrameSource timer queue
  tick()
    sampleForCurrentTime()  ← playbackClock from VideoAudioPlayer
    emit(sampleBuffer)
      onPreviewBuffer → overlay preview [if shouldEmitPreview]
      onFrameBGRA(vImage_Buffer)
        SessionController.process(bgra:)
          (same as region from here)
```

## Complete Call Graph: User Starts Stream

```
SettingsPaneView Start button (or wledcast-ctl stream start)
  AppModel.startStreaming()
    syncFpsFromSelectedHost()
    ensureScreenPermission() [region]
    DDPSender(host)
    SessionController(sender, ...)
    PerfLog.configure + stream_start
    [video] VideoAudioPlayer + VideoFrameSource
    [region] DisplayFrameSource
    isStreaming = true
```
