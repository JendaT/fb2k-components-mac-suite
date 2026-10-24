# foo_jl_spectrogram

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/spectrogram.md)**

---

A scrolling spectrogram UI element for foobar2000 macOS. Reads raw PCM from the core `visualisation_manager`, runs reassigned or multi-resolution FFTs with Accelerate, and scrolls the result as Core Animation tile layers.

Contributed by [Scannou](https://github.com/Scannou).

## Requirements

- foobar2000 for Mac 2.x
- macOS 12.0+ (Monterey or later)
- Xcode 12+ with Command Line Tools (for building from source)
- Ruby (for project generation)

## Quick Start

### Build and Install

```bash
# From this directory
./Scripts/build.sh --install            # Build Release and install
./Scripts/build.sh --clean --install    # Clean rebuild and install
./Scripts/build.sh --regenerate --install  # After adding/removing source files

# Restart foobar2000, then add the UI element
```

### From Binary

1. Download `foo_jl_spectrogram.fb2k-component` from Releases
2. Create folder: `~/Library/foobar2000-v2/user-components/foo_jl_spectrogram/`
3. Copy `foo_jl_spectrogram.component` into that folder
4. Restart foobar2000

## Build Scripts

All scripts are located in the `Scripts/` directory and share `shared/scripts/lib.sh`.

| Script | Purpose |
|--------|---------|
| `build.sh` | Run unit tests, then build (`--debug`, `--release`, `--clean`, `--regenerate`, `--install`) |
| `run_tests.sh` | Compile and run the Core unit tests standalone (`--coverage`) |
| `install.sh` | Install a pre-built component (`--config Debug`) |
| `clean.sh` | Remove build artifacts |
| `generate_xcode_project.rb` | Generate the Xcode project from `src/` |

Never call `xcodebuild` directly; `build.sh` keeps output in the local `build/` directory so `install.sh` copies the binary you just built.

## Usage

### Adding to Layout

1. **View → Layout → Enable Layout Editing Mode**
2. Right-click and choose **Add UI Element**
3. Select **Spectrogram**

Layout file names: `spectrogram` (also `Spectrogram`, `foo_jl_spectrogram`, `jl_spectrogram`).

### Configuration

Access settings in **Preferences > Display > Spectrogram**, or right-click the element and choose **Preferences...**.

See [docs/spectrogram.md](../../docs/spectrogram.md) for the full settings reference.

## Project Structure

```
foo_jl_spectrogram_mac/
├── src/
│   ├── Core/
│   │   ├── SpectrogramEngine.h/cpp     # PCM window -> one column of levels (pure C++ + Accelerate)
│   │   ├── SpectrogramColormaps.h      # Color ramps and lookup tables (pure C++)
│   │   ├── SpectrogramClock.h          # Columns due per frame from the stream time (pure C++)
│   │   └── SpectrogramConfig.h         # Config keys, enums, defaults, configStore accessors
│   ├── UI/
│   │   ├── SpectrogramView.h/mm        # Tile layers, frequency axis, dB scale, probe
│   │   ├── SpectrogramController.h/mm  # View controller, display link, column rendering, quit handling
│   │   └── SpectrogramPreferences.h/mm # Preferences page
│   ├── Integration/
│   │   ├── SpectrogramSource.h/cpp     # Visualisation stream reads (the SDK boundary)
│   │   └── Main.mm                     # UI element and component registration
│   ├── fb2k_sdk.h                      # SDK configuration
│   └── Prefix.pch                      # Precompiled header
├── Tests/                              # Standalone unit tests for Core
├── Resources/
│   └── Info.plist
├── Scripts/
└── README.md
```

## Technical Details

- Samples come from `visualisation_stream_v2::get_chunk_absolute`; each column reads a window centred on its own time, so column spacing does not depend on frame timing.
- `SpectrogramEngine`, `SpectrogramColormaps`, and `SpectrogramClock` have no SDK or Cocoa dependency and are unit-tested standalone; the tests gate the build.
- The picture is a strip of 256-column tile layers; only the newest is re-uploaded each frame.
- A `CADisplayLink` (macOS 14+, else a 60 fps `NSTimer`) drives the view; it pauses when the view is hidden and the stream is released so the core can stop the visualisation backend.
- An `initquit` service releases all live streams before service teardown; holding a stream through shutdown aborts the app.
- Settings persist through `fb2k::configStore` under the `foo_jl_spectrogram.` prefix.

## License

MIT License - see LICENSE file
