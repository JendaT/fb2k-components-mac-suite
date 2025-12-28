# Waveform Seekbar

An interactive waveform display and seekbar for foobar2000 macOS.

## Features

### Complete Waveform Display

Shows the entire track waveform at a glance - not just the current audio buffer. See the full structure of your music including quiet intros, build-ups, and loud sections.

<!-- Screenshot: Waveform overview -->
![Waveform Seekbar Overview](images/waveform-overview.png)

### Interactive Seeking

Click anywhere on the waveform to seek to that position. The playback position is clearly indicated with a visual marker.

### Display Modes

| Mode | Description |
|------|-------------|
| **Stereo** | Left and right channels displayed separately |
| **Mono** | Combined single waveform |

<!-- Screenshot: Stereo vs mono comparison -->

### Played Position Indicator

Visual indication of playback progress with subtle gradient fade showing what has been played.

### Waveform Caching

SQLite-based cache stores analyzed waveforms for instant loading:
- SHA-256 hash keys for reliable file identification
- Configurable cache size (default: 2GB)
- Automatic LRU eviction when limit reached
- WAL mode for concurrent access

### Customizable Colors

Configure colors to match your theme:
- Waveform color
- Played area color
- Background color

### BPM Sync

Automatically reads BPM from track metadata for potential beat-aligned features. Supports common tags:
- BPM
- TBPM
- TEMPO

### Dark Mode Support

Automatic color adaptation for macOS light and dark appearances.

### Retina Display

Crisp rendering on high-DPI displays using native `backingScaleFactor`.

## Configuration

Access settings via **Preferences > Display > Waveform Seekbar**

<!-- Screenshot: Settings panel -->
![Waveform Settings](images/waveform-settings.png)

### Available Settings

| Setting | Description | Default |
|---------|-------------|---------|
| Display Mode | Stereo or Mono | Stereo |
| Waveform Color | Color of the waveform | System accent |
| Played Color | Color of played portion | Dimmed accent |
| Background Color | Background color | Window background |
| Cache Size | Maximum cache size in MB | 2048 |
| Cache Retention | Days to keep unused data | 180 |

### Cache Location

Waveform data is cached at:
```
~/Library/foobar2000-v2/waveform_cache/waveforms.db
```

## Layout Editor

Add Waveform Seekbar to your layout using any of these names:
- `waveform-seekbar` (recommended)
- `Waveform Seekbar`
- `waveform_seekbar`
- `foo_jl_wave_seekbar`

Example layout:
```
splitter vertical
  waveform-seekbar
  simplaylist
```

## Technical Details

### Audio Analysis

- Uses Apple Accelerate framework (vDSP) for SIMD-optimized processing
- Background scanning with Grand Central Dispatch
- Cancellation support for track changes
- 2048 peak buckets per track for detailed visualization

### Rendering

- Core Graphics (Quartz 2D) for native performance
- Layer-backed view for smooth animation
- 60 FPS timer for position updates

## Requirements

- foobar2000 v2.x for macOS
- macOS 11.0 (Big Sur) or later

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_wave_seekbar_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_wave_seekbar_mac/README.md)
