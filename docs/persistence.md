# Persistence

Where state is stored and how it flows.

## UserDefaults

Written by `AppModel.persist()`, read by `AppModel.restore()`.

| Key | Type | Default | Written When |
|-----|------|---------|--------------|
| `lastHost` | String | `""` | Host change |
| `aspectLock` | Bool | `true` | Toggle |
| `captureMode` | String | `"region"` | Mode change |
| `selectedVideoPath` | String | nil | Video selection |
| `loopVideo` | Bool | `true` | Toggle |
| `overlayMosaicEnabled` | Bool | `true` | Toggle |
| `audioVolume` | Double | `1.0` | Slider |
| `audioMuted` | Bool | `false` | Toggle |
| `outputResolution` | JSON Data | nil | Host profile apply |
| `targetFps` | Int | 42 | Host profile apply |
| `filters` | JSON Data | defaults | Filter change |
| `flickerFighter` | Double | `0` | Slider |
| `captureBox` | JSON Data | centered | Overlay drag/resize |

### JSON-encoded types

- `OutputResolution`
- `FilterConfig`
- `CaptureBox`

### Legacy migration

Previously stored in UserDefaults, now migrated to file store on first launch:

| Old Key | New Location |
|---------|--------------|
| `videoCropBox` | `VideoSettingsStore` |
| `loopRange` | `VideoSettingsStore` |

`migrateLegacyVideoSettings()` runs once per selected video, then removes old keys.

---

## Video Settings File

**Path:** `~/Library/Application Support/WledCast/video-settings.json`

**Format:**

```json
{
  "dQw4w9WgXcQ": {
    "crop": { "x": 0, "y": 0, "width": 1, "height": 1 },
    "loopRange": { "start": 0, "end": 1 }
  },
  "my-local-video": {
    "crop": { "x": 0.1, "y": 0, "width": 0.8, "height": 1 },
    "loopRange": { "start": 0.2, "end": 0.8 }
  }
}
```

**Key derivation (`VideoKey.from(url)`):**

1. Take filename stem (no extension)
2. If stem ends with 11-char YouTube ID pattern → use ID as key
3. Else use full stem

**Operations:**

| Method | When |
|--------|------|
| `settings(for: url)` | Video selected, library refresh |
| `save(_:for: url)` | Crop change, loop range commit |
| `prune(keeping: urls)` | Library refresh removes deleted videos |

Managed by `VideoSettingsStore` with file lock. Atomic write.

---

## Video Library Directory

**Resolution order** (`AppModel.resolvedVideoDirectoryURL()`):

1. `{cwd}/Videos/` if contains `.mp4`
2. `{app bundle sibling}/Videos/` if contains `.mp4`
3. `{app bundle parent}/Videos/` if contains `.mp4`
4. `{app bundle parent}/Videos/` if it exists (even without `.mp4`)
5. `{app bundle sibling}/Videos/` if it exists
6. `{cwd}/Videos/` (created on demand)

Created on demand. Only `.mp4` files listed, sorted by filename.

YouTube downloads land here via `fetch_video.sh`.

---

## Log & Agent Files

**Directory resolution** (`LogPaths`):

1. `$WLEDCAST_LOG_DIR` if set
2. `{repo}/logs/` when repo root found (Package.swift or .git)
3. `~/Library/Logs/WledCast/`

| File | Writer | Purpose |
|------|--------|---------|
| `wledcast.log` | `FileLog` | Structured app log, 1MB trim |
| `perf.log` | `PerfLog` | ISO8601 perf events |
| `agent.json` | `PerfLog` | Agent-readable metrics snapshot |
| `control.sock` | `AgentControlServer` | Headless control socket |

**Log channels:** app, permissions, discovery, session, transport, capture

**Subsystem:** `io.wledcast.native` (mirrored to os.log)

See [Agent Control](agent.md) for protocol and snapshot schema.

---

## Runtime State (not persisted)

| State | Location | Cleared |
|-------|----------|---------|
| `hosts` | AppModel | Never (from discovery) |
| `isStreaming` | AppModel | stopStreaming |
| `senderState` | AppModel | DDPSender lifecycle |
| `fetchState` | AppModel | fetch complete/fail |
| `lastMosaicImage` | AppModel | stopStreaming |
| `streamingSourceFps` | AppModel | video stream start |
| `isLoopScrubbing` | AppModel | commitLoopRange |
| `savedHostReachabilityChecked` | AppModel | setHost |
| Session/sender/sources | AppModel private | stopStreaming |
| `verifiedHosts` | WLEDDiscoveryClient actor | app lifetime |
| DDP sequence ID | DDPPacketizer | app lifetime |
| TemporalSmoother previous frame | SessionController | new session |
| PreviewGate last emit times | AppModel | fps change |
| PerfLog session/window metrics | PerfLog | stream stop |

---

## Data Flow: Settings Change → Disk

```
User adjusts filter in SettingsPaneView
  → model.setFilters(newValue)
    → filters = newValue                    (@Published, UI updates)
    → session?.updateFilters(newValue)        (live, next frame)
    → persist()
      → JSONEncoder.encode(filters)
      → UserDefaults.set(data, "filters")
```

```
User adjusts crop in overlay
  → overlay.onVideoCropChange(crop)
    → videoCropBox = crop
    → videoSource?.updateCrop(crop)           (live)
    → saveCurrentVideoSettings()
      → VideoSettingsStore.save(...)
        → JSON file atomic write
```

```
Host discovered with new resolution
  → applyHostProfile(profile)
    → outputResolution, targetFps, fps
    → overlay.outputResolution = ...
    → persist()
    → restartStreaming() or autoStart()
```
