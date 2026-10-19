# foo_jl_wave_seekbar

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/waveform.md)** | **[Changelog](CHANGELOG.md)**

---

An interactive waveform display and seekbar for foobar2000 macOS.

## Requirements

- foobar2000 for Mac 2.x
- macOS 12.0+ (Monterey or later)
- Xcode 12+ with Command Line Tools (for building from source)
- Ruby (for project generation)

## Quick Start

### Build and Test Install

```bash
# One-command build and install for testing
./Scripts/test_install.sh

# Restart foobar2000, then add the UI element
```

### From Binary

1. Download `foo_jl_wave_seekbar.fb2k-component` from Releases
2. Create folder: `~/Library/foobar2000-v2/user-components/foo_jl_wave_seekbar/`
3. Copy `foo_jl_wave_seekbar.component` into that folder
4. Restart foobar2000

## Build Scripts

All scripts are located in the `Scripts/` directory.

### test_install.sh

The primary script for development - performs a clean build and installs to foobar2000 for testing.

```bash
./Scripts/test_install.sh           # Clean build (Release) and install
./Scripts/test_install.sh --debug   # Build Debug configuration
./Scripts/test_install.sh --no-clean # Skip cleaning, faster rebuild
./Scripts/test_install.sh --regenerate # Force regenerate Xcode project
```

### build.sh

Build the component with various options.

```bash
./Scripts/build.sh                  # Build Release
./Scripts/build.sh --debug          # Build Debug
./Scripts/build.sh --clean          # Clean before building
./Scripts/build.sh --regenerate     # Regenerate Xcode project first
./Scripts/build.sh --install        # Build and install
./Scripts/build.sh --clean --install # Full clean build and install
```

### install.sh

Install a pre-built component to foobar2000.

```bash
./Scripts/install.sh                # Install Release build
./Scripts/install.sh --config Debug # Install Debug build
```

### clean.sh

Remove build artifacts.

```bash
./Scripts/clean.sh           # Clean build directory
./Scripts/clean.sh --all     # Also remove generated Xcode project
```

### generate_xcode_project.rb

Generate the Xcode project from source files.

```bash
ruby Scripts/generate_xcode_project.rb
```

This script:
- Discovers all source files in `src/`
- Configures SDK library linking
- Sets up framework dependencies
- Creates `foo_jl_wave_seekbar.xcodeproj`

## Manual Build Commands

If you prefer using xcodebuild directly:

```bash
# Generate project (required first time)
ruby Scripts/generate_xcode_project.rb

# Build Release
xcodebuild -project foo_jl_wave_seekbar.xcodeproj -target foo_jl_wave_seekbar -configuration Release build

# Build Debug
xcodebuild -project foo_jl_wave_seekbar.xcodeproj -target foo_jl_wave_seekbar -configuration Debug build

# Clean
xcodebuild -project foo_jl_wave_seekbar.xcodeproj -target foo_jl_wave_seekbar clean
```

## Usage

### Adding to Layout

1. Right-click on the foobar2000 window
2. Select "Add UI Element"
3. Choose "Waveform Seekbar" from the list

### Seeking

- **Click** anywhere on the waveform to seek to that position
- **Drag** to preview position before releasing

### Configuration

Access settings in **Preferences > Display > Waveform Seekbar**

Settings sit on three cards, plus the cache:

| Card | Setting | Description | Default |
|------|---------|-------------|---------|
| Appearance | Style | Layered (peak envelope around a momentary loudness body tinted by the spectral balance, one dBFS axis); Simple: Two-tone, Glow, Heat (split L/R lanes on black, linear); Classic: Heat map, Rainbow, Solid (the original styles) | Layered |
| Appearance | Body tint | Layered: the body darker where bass dominates, lighter where highs do: Off, Subtle, Strong | Subtle |
| Appearance | Gradient bands | Classic Solid: steps from the centre out (0 = flat, up to 32) | 8 |
| Appearance | Channels | Stereo (L / R apart) or Mono (mixed into one) | Stereo |
| Appearance | Colours | Theme preset (the Spectrum Analyzer themes) and its light / dark waveform and background colours; editing a colour switches to Custom | P4 white |
| Appearance | Played opacity | How strongly the part already played is drawn (20-100 %) | 72 % |
| Appearance | Glass background | Translucent blur instead of the background colour | Off |
| Overlays | Text size | Readout, summary, cursor time and scale labels: 10, 12, 14 or 16 pt | 12 pt |
| Overlays | Readout on hover | Time, LUFS-S, peak, crest, correlation and Lo/Mid/Hi split under the mouse; click seeks. Follows the mouse, or sits top right, or bottom right above the summary | On, follows the mouse |
| Overlays | Elapsed time on the cursor | m:ss chip beside the playback cursor | Off |
| Overlays | Loudness summary | Integrated, LRA, true peak, PLR, clip count: Off, On hover, Always | On hover |
| Overlays | Clip markers | Ticks on the top edge for runs of 3+ samples at full scale | On |
| Scales | Time ruler below the waveform | Ticks and m:ss labels; off gives the waveform full height | Off |
| Scales | Level scale on the right | dB labels in a gutter; off gives the waveform full width | On |
| Cache | Max size / Keep for | Disk space and days to keep unused analysis | 2048 MB, 180 days |

## Project Structure

```
foo_jl_wave_seekbar_mac/
├── src/
│   ├── Core/                        # Platform-agnostic logic
│   │   ├── WaveformData.h/cpp       # Cached per-track analysis (blocks, hops, summary)
│   │   ├── TrackAnalyzer.h/cpp      # Analysis pass: loudness, LRA, true peak, bands, clips
│   │   ├── ColumnAggregator.h/cpp   # Per-column values for a view width
│   │   ├── LayeredShape.h           # Layered style geometry
│   │   ├── SimpleShape.h            # Simple styles' lane geometry
│   │   ├── ThemeTokens.h/cpp        # OKLCH colour tokens
│   │   ├── OverlayText.h            # Overlay / scale formatting
│   │   ├── WaveformThemes.h         # Theme presets
│   │   ├── WaveformScanner.h/cpp    # Async decode through the analyser
│   │   ├── WaveformCache.h/cpp      # SQLite persistence (WAL mode)
│   │   ├── WaveformService.h/cpp    # Coordination layer
│   │   ├── WaveformConfig.h/cpp     # Configuration (cfg_var)
│   │   ├── cfg_var_legacy_stubs.cpp # SDK compatibility
│   │   └── pfc_debug.cpp            # Debug build support
│   ├── UI/                          # Cocoa views
│   │   ├── WaveformSeekbarView.h/mm # Main waveform NSView
│   │   ├── WaveformSeekbarController.h/mm # View controller
│   │   └── WaveformPreferences.h/mm # Preferences page
│   ├── Integration/                 # SDK registration
│   │   ├── Main.mm                  # Component registration
│   │   └── PlaybackCallback.h/mm    # Playback events
│   ├── fb2k_sdk.h                   # SDK configuration
│   └── Prefix.pch                   # Precompiled header
├── Resources/
│   └── Info.plist                   # Bundle metadata
├── Tests/                           # Standalone unit tests for src/Core
├── Scripts/
│   ├── generate_xcode_project.rb    # Project generator
│   ├── build.sh                     # Build script (runs the unit tests first)
│   ├── run_tests.sh                 # Unit tests
│   ├── install.sh                   # Install script
│   ├── clean.sh                     # Clean script
│   └── test_install.sh              # Build + install for testing
├── docs/
│   └── ARCHITECTURE.md              # Technical documentation
└── README.md
```

## Technical Details

### Analysis

One decode pass per track (`TrackAnalyzer`), cached:
- Fine blocks of ~1024 frames (fewer, larger blocks past ~6 min): sample min/max and RMS per channel
- 100 ms hops: K-weighted (BS.1770) power, plain power and L*R per channel, Lo/Mid/Hi band power (250 Hz / 2 kHz Linkwitz-Riley, as the Vectorscope)
- Clip runs: 3+ consecutive samples at |x| >= 0.9999
- Summary: integrated loudness (BS.1770-4 gating), LRA (EBU Tech 3342), true peak (4x oversampled), PLR, clip count
- Per-column values are aggregated from the blocks at draw time, so a resize never re-decodes
- Stored zlib-compressed with levels in 0.01 dB steps and samples in 16 bits (~100-300 KB per track)

### Scanning Performance

| Track Duration | Typical Scan Time |
|----------------|-------------------|
| 3 min (FLAC)   | ~0.5-1.0 sec |
| 10 min (FLAC)  | ~1.5-2.5 sec |
| 3 min (MP3)    | ~0.3-0.5 sec |

- Analysis adds about 0.9 s per 10 minutes of stereo on top of decoding
- Background scanning with GCD
- Cancellation support for track changes

### Cache

- Location: `~/Library/foobar2000-v2/waveform_cache/waveforms.db`
- SQLite with WAL mode for concurrent access
- SHA-256 hash keys for file identification
- Default max size: 2048 MB
- Automatic LRU eviction when limit reached

### Rendering

- The waveform's layers are cached as greyscale masks per track, pixel size and style family, then coloured into one composite per theme and style; a theme change recolours without re-analysis
- Frames draw the composite twice under two clip rects (played part at Played opacity), then guides, cursor and overlays
- One column per screen pixel (merged blocks on narrow views, interpolated on wide ones)
- Deep / hot / guide colours derive from the theme accent in OKLCH
- Unit tests (`Scripts/run_tests.sh`, run by `build.sh`) cover the analysis, column aggregation, shapes, colour tokens and overlay formatting

## Troubleshooting

### Component doesn't load

1. Check Preferences > Components for error messages
2. Verify the component is in `~/Library/foobar2000-v2/user-components/foo_jl_wave_seekbar/foo_jl_wave_seekbar.component`
3. Try rebuilding with `./Scripts/test_install.sh --regenerate`

### Waveform not displaying

1. Wait for the scan to complete (check console for progress)
2. Verify the track format is supported
3. Check cache directory permissions

### Build errors

1. Ensure SDK is built: `cd ../SDK-2026-10-01 && xcodebuild`
2. Regenerate project: `./Scripts/clean.sh --all && ./Scripts/test_install.sh`

## Credits

- Based on [foo_wave_seekbar](https://github.com/zao/foo_wave_seekbar) for Windows by zao
- Uses algorithms and data structures from the original implementation

## License

MIT License - see LICENSE file

## Changelog

### 1.0.0 (2024)

- Initial release
- Waveform display with stereo/mono modes
- Interactive click-to-seek
- SQLite caching with WAL mode
- Dark mode support
- Full preferences page with color customization
- Universal binary (arm64 + x86_64)
