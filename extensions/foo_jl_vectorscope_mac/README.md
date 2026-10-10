# foo_jl_vectorscope

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/vectorscope.md)**

---

A stereo vectorscope (goniometer) UI element with a phase correlation meter for foobar2000 macOS. Reads raw stereo samples from the core `visualisation_manager` and renders an oscilloscope-style afterglow trace.

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
./Scripts/build.sh --install            # Run tests, build Release and install
./Scripts/build.sh --clean --install    # Clean rebuild and install
./Scripts/build.sh --regenerate --install  # After adding/removing source files

# Restart foobar2000, then add the UI element
```

### From Binary

1. Download `foo_jl_vectorscope.fb2k-component` from Releases
2. Create folder: `~/Library/foobar2000-v2/user-components/foo_jl_vectorscope/`
3. Copy `foo_jl_vectorscope.component` into that folder
4. Restart foobar2000

## Build Scripts

All scripts are located in the `Scripts/` directory and share `shared/scripts/lib.sh`.

| Script | Purpose |
|--------|---------|
| `build.sh` | Run tests, then build (`--debug`, `--release`, `--clean`, `--regenerate`, `--install`) |
| `run_tests.sh` | Compile and run the Core unit tests standalone (`--coverage`) |
| `install.sh` | Install a pre-built component (`--config Debug`) |
| `clean.sh` | Remove build artifacts |
| `generate_xcode_project.rb` | Generate the Xcode project from `src/` |

Never call `xcodebuild` directly; `build.sh` keeps output in the local `build/` directory so `install.sh` copies the binary you just built.

## Usage

### Adding to Layout

1. **View → Layout → Enable Layout Editing Mode**
2. Right-click and choose **Add UI Element**
3. Select **Vectorscope**

Layout file names: `vectorscope` (also `Vectorscope`, `vector_scope`, `goniometer`, `foo_jl_vectorscope`, `jl_vectorscope`).

### Configuration

Access settings in **Preferences > Display > Vectorscope**, or right-click the element and choose **Preferences...**.

See [docs/vectorscope.md](../../docs/vectorscope.md) for the full settings reference.

## Project Structure

```
foo_jl_vectorscope_mac/
├── src/
│   ├── Core/
│   │   ├── StereoAnalysis.h/cpp       # Goniometer mapping, correlation, band split, auto gain (pure C++)
│   │   ├── PhosphorBuffer.h/cpp       # Afterglow intensity buffer and color table (pure C++)
│   │   ├── VectorscopeConfig.h        # Config keys, enums, defaults, configStore accessors
│   │   └── VectorscopeThemes.h        # Color theme presets
│   ├── UI/
│   │   ├── VectorscopeView.h/mm        # Grid, correlation bars, trace layer
│   │   ├── VectorscopeController.h/mm  # View controller, 60 fps timer, glass background, quit handling
│   │   └── VectorscopePreferences.h/mm # Preferences page
│   ├── Integration/
│   │   ├── ScopeSource.h/cpp          # Stereo sample pull from the visualisation stream (SDK boundary)
│   │   └── Main.mm                    # UI element and component registration
│   ├── fb2k_sdk.h                     # SDK configuration
│   └── Prefix.pch                     # Precompiled header
├── Tests/
│   ├── StereoAnalysisTests.cpp
│   ├── PhosphorBufferTests.cpp
│   └── TestHarness.h
├── Resources/
│   └── Info.plist
├── Scripts/
└── README.md
```

## Technical Details

- Samples come from `visualisation_stream_v2::get_chunk_absolute`; each frame reads the audio played since the previous frame.
- `StereoAnalysis` and `PhosphorBuffer` have no SDK or Cocoa dependency and are unit-tested standalone; the tests gate the build.
- The trace is a CPU intensity buffer (faded and added to each frame), color-mapped and shown as a layer image above the Core Graphics grid.
- A 60 fps `NSTimer` drives the view; it pauses when the view is hidden and the stream is released so the core can stop the visualisation backend.
- An `initquit` service releases all live streams before service teardown; holding a stream through shutdown aborts the app.
- Settings persist through `fb2k::configStore` under the `foo_jl_vectorscope.` prefix.

## License

MIT License - see LICENSE file
