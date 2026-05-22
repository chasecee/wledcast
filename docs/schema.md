# Schema

All domain types, wire formats, and API contracts.

## Domain Types (`Sources/WledCore/Domain/Models.swift`)

### CaptureBox

Screen-region capture rectangle in display coordinates.

```swift
struct CaptureBox: Codable, Equatable, Sendable {
    var displayID: UInt32   // CGDirectDisplayID
    var left: Int           // screen X
    var top: Int            // screen Y
    var width: Int
    var height: Int
}
```

Factory: `CaptureBox.centered(on: NSScreen)` for initial placement.

### OutputResolution

WLED matrix dimensions.

```swift
struct OutputResolution: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
}
```

### FilterConfig

Image processing parameters applied in `FramePipeline`.

```swift
struct FilterConfig: Codable, Equatable, Sendable {
    var sharpen: Float       // 0 = off; kernel strength when non-zero
    var saturation: Float    // 1.0 = normal
    var brightness: Float    // gain combined with balanceR/G/B and contrast
    var contrast: Float      // 1.0 = normal
    var balanceR: Float
    var balanceG: Float
    var balanceB: Float
}
```

Defaults: sharpen 0.1, saturation 1.0, brightness 0.3, contrast 1.0, balanceR/G/B 1.0/0.7/0.45.

### CaptureMode

```swift
enum CaptureMode: String, Codable {
    case region   // ScreenCaptureKit subregion
    case video    // Local MP4 file
}
```

Note: README mentions display/window modes; only `region` and `video` are implemented.

### VideoCropBox

Normalized crop within video frame (0–1).

```swift
struct VideoCropBox: Codable, Equatable, Sendable {
    var x, y, width, height: Double
}
static let full = VideoCropBox(x: 0, y: 0, width: 1, height: 1)
```

### LoopRange

Normalized playback segment (0–1).

```swift
struct LoopRange: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    static let minSpan: Double = 0.01
    func clamped() -> LoopRange  // enforces minSpan
}
```

### CaptureSelection

Passed to `DisplayFrameSource`; only `displayID` is used in practice.

```swift
struct CaptureSelection: Codable, Equatable, Sendable {
    var mode: CaptureMode
    var displayID: UInt32?
    var windowID: UInt32?    // unused in current capture path
}
```

### WLEDHost / WLEDHostProfile

```swift
struct WLEDHost: Codable, Identifiable {
    static let defaultFps = 42
    let host: String
    let resolution: OutputResolution
    let targetFps: Int
    var effectiveFps: Int { targetFps > 0 ? targetFps : defaultFps }
}

struct WLEDHostProfile: Equatable, Sendable {
    let resolution: OutputResolution
    let targetFps: Int
    var effectiveFps: Int
}
```

### RGBFrame

Final pixel buffer sent to WLED.

```swift
struct RGBFrame: Equatable, Sendable {
    let width: Int
    let height: Int
    var pixels: [UInt8]   // count = width × height × 3, RGB order
    func flattenedData() -> Data
}
```

### VideoSettings (`VideoSettings.swift`)

Per-video persisted settings.

```swift
struct VideoSettings: Codable, Equatable, Sendable {
    var crop: VideoCropBox
    var loopRange: LoopRange
}
```

Keyed by `VideoKey.from(url)`: YouTube ID from filename suffix `[A-Za-z0-9_-]{11}` or file stem.

### AppOptions

Defined in Models.swift but unused in app code (legacy/CLI placeholder).

```swift
struct AppOptions {
    var host: String?
    var title: String?
    var monitor: Int?
    var outputResolution: OutputResolution?
    var fps: Int
    var searchTimeout: TimeInterval
    var livePreview: Bool
}
```

### Agent Control (`AgentControl.swift`)

```swift
struct AgentControlRequest: Codable, Sendable {
    var cmd: String
    var value: Int?      // fps.set
    var seconds: Double? // reserved
}

struct AgentControlResponse: Codable, Sendable {
    var ok: Bool
    var error: String?
    var data: [String: String]?
}
```

See [Agent Control](agent.md) for commands and wire format.

---

## WLED HTTP API

Base: `http://{host}:80`

### GET /json/info

Response shape (parsed by `WLEDInfoParser`):

```json
{
  "leds": {
    "matrix": { "w": 32, "h": 8 },
    "fps": 42
  }
}
```

| Field | Usage |
|-------|-------|
| `leds.matrix.w/h` | Required. `OutputResolution`. Missing → `WLEDInfoError.notAMatrix` |
| `leds.fps` | Parsed but not used for target FPS |

### GET /cfg.json or GET /json/cfg

```json
{
  "hw": {
    "led": {
      "fps": 42
    }
  }
}
```

| Field | Usage |
|-------|-------|
| `hw.led.fps` | Target FPS. `0` = unlimited (shown as "Unlimited" in UI, effective 42) |
| Missing cfg | Falls back to `WLEDHost.defaultFps` (42) |

HTTP client: 2s timeout, ephemeral session, no cache.

---

## DDP Wire Format (`DDPPacketizer`)

| Constant | Value |
|----------|-------|
| Port | 4048 |
| Max payload | 1200 bytes |
| Destination ID | 1 |
| Data type | 0x0B (RGB) |

### Packet Header (10 bytes)

| Offset | Size | Field |
|--------|------|-------|
| 0 | 1 | Flags: `0x40` base, `+0x01` if last fragment |
| 1 | 1 | Sequence ID (0–15, increments per frame) |
| 2 | 1 | Data type `0x0B` |
| 3 | 1 | Destination ID `1` |
| 4–7 | 4 | Data offset (big-endian UInt32) |
| 8–9 | 2 | Chunk length (big-endian UInt16) |

Bytes 10+ = RGB payload.

Full frame = `width × height × 3` bytes, split into ≤1200-byte chunks.

Test fixture: `Tests/WledCoreTests/Fixtures/ddp_fixture.json`

---

## Internal Protocols

### HTTPClient

```swift
protocol HTTPClient: Sendable {
    func get(url: URL) async throws -> (Data, HTTPURLResponse)
}
```

Default: `URLSessionHTTPClient(timeout: 2.0)`.

### Callback Contracts

| Callback | Type | Emitter |
|----------|------|---------|
| `onFrameBGRA` | `(vImage_Buffer) -> Void` | DisplayFrameSource, VideoFrameSource |
| `onPreviewBuffer` | `(CVPixelBuffer) -> Void` | VideoFrameSource |
| `shouldEmitPreview` | `() -> Bool` | VideoFrameSource |
| `onFrameProcessed` | `([UInt8], Int, Int) -> Void` | SessionController (pixels, width, height) |
| `shouldProcessPreview` | `() -> Bool` | SessionController |
| `onStateChanged` | `(DDPSenderState) -> Void` | DDPSender |
| `onChange` | `(CaptureBox) -> Void` | OverlayWindowController |
| `onVideoCropChange` | `(VideoCropBox) -> Void` | OverlayWindowController |
| `onDiagnostics` | `(Diagnostics) -> Void` | DisplayFrameSource |

### DDPSenderState

```swift
enum DDPSenderState: Equatable, Sendable {
    case connecting
    case ready
    case failed(String)
    case stopped
}
```

### FetchState (AppModel)

```swift
enum FetchState: Equatable {
    case idle
    case running
    case failed(String)
}
```

### LoopScrubHandle (`SettingsPaneView.swift`)

```swift
enum LoopScrubHandle { case start, end }
```

Used by `AppModel.scrubLoopRange(handle:ratio:)` for loop range UI.

---

## Bonjour Service

| Field | Value |
|-------|-------|
| Type | `_wled._tcp` |
| Domain | `local` |
| Resolved hostname | `{name}.local` |

Candidates probed via HTTP before appearing in verified host list.

---

## YouTube Fetch Protocol

Script: `Scripts/fetch_video.sh`

Invocation: `bash fetch_video.sh {url}`

Success output includes line: `saved: /path/to/file.mp4 (optional metadata)`

Parsed by `YouTubeDownloader.parseSavedPath(from:)`.

Errors: `YouTubeDownloaderError` (invalidURL, scriptNotFound, outputParseFailed, scriptFailed).
