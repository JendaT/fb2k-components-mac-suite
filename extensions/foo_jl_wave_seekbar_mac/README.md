# foo_jl_wave_seekbar

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/waveform.md)** | **[Changelog](CHANGELOG.md)**

---

An interactive waveform display and seekbar for foobar2000 macOS.

## Requirements

- foobar2000 for Mac 2.x
- macOS 11.0+ (Big Sur or later)
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

| Setting | Description | Default |
|---------|-------------|---------|
| Display Mode | Stereo (separate L/R) or Mono (combined) | Stereo |
| Shade Played | Dim the portion already played | On |
| Flip Display | Reverse waveform direction | Off |
| Waveform Color | Color for the waveform peaks | Blue |
| Played Color | Overlay color for played portion | Semi-transparent |
| Background | Background color | Theme-dependent |
| Cache Size | Maximum disk space for waveform cache | 2048 MB |
| Cache Retention | Days to keep unused waveform data | 180 days |

## Project Structure

```
foo_jl_wave_seekbar_mac/
├── src/
│   ├── Core/                        # Platform-agnostic logic
│   │   ├── WaveformData.h/cpp       # Peak data structure (2048 buckets)
│   │   ├── WaveformScanner.h/cpp    # Audio scanning with vDSP
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
├── Scripts/
│   ├── generate_xcode_project.rb    # Project generator
│   ├── build.sh                     # Build script
│   ├── install.sh                   # Install script
│   ├── clean.sh                     # Clean script
│   └── test_install.sh              # Build + install for testing
├── docs/
│   └── ARCHITECTURE.md              # Technical documentation
└── README.md
```

## Technical Details

### Waveform Data

- Fixed resolution of 2048 buckets per track
- Stores min/max/RMS values per channel (up to stereo)
- Compressed with zlib for storage (~10-15KB per stereo track)
- Little-endian serialization for portability

### Scanning Performance

| Track Duration | Typical Scan Time |
|----------------|-------------------|
| 3 min (FLAC)   | ~0.5-1.0 sec |
| 10 min (FLAC)  | ~1.5-2.5 sec |
| 3 min (MP3)    | ~0.3-0.5 sec |

- Uses Apple Accelerate framework (vDSP) for SIMD optimization
- Background scanning with GCD
- Cancellation support for track changes

### Cache

- Location: `~/Library/foobar2000-v2/waveform_cache/waveforms.db`
- SQLite with WAL mode for concurrent access
- SHA-256 hash keys for file identification
- Default max size: 2048 MB
- Automatic LRU eviction when limit reached

### Rendering

- Core Graphics (Quartz 2D) for native performance
- Layer-backed view for smooth animation
- 60 FPS timer for position updates
- Retina display support via `backingScaleFactor`

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

1. Ensure SDK is built: `cd ../SDK-2025-03-07 && xcodebuild`
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
