# foo_jl_levelmeter

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/levelmeter.md)**

---

A peak, RMS and loudness meter UI element for foobar2000 macOS, with an optional analog VU look. Reads raw samples from the core `visualisation_manager` and draws digital bars with loudness and stereo figures, or backlit needle faces.

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

1. Download `foo_jl_levelmeter.fb2k-component` from Releases
2. Create folder: `~/Library/foobar2000-v2/user-components/foo_jl_levelmeter/`
3. Copy `foo_jl_levelmeter.component` into that folder
4. Restart foobar2000

## Build Scripts

All scripts are located in the `Scripts/` directory and share `shared/scripts/lib.sh`.

| Script | Purpose |
|--------|---------|
| `build.sh` | Run tests, then build (`--debug`, `--release`, `--clean`, `--regenerate`, `--install`) |
| `run_tests.sh` | Compile and run the Core unit tests standalone (`--coverage`) |
| `preview.sh` | Render sample meter panels to PNG without foobar2000 (default output `build/preview/`) |
| `install.sh` | Install a pre-built component (`--config Debug`) |
| `clean.sh` | Remove build artifacts |
| `generate_xcode_project.rb` | Generate the Xcode project from `src/` |

Never call `xcodebuild` directly; `build.sh` keeps output in the local `build/` directory so `install.sh` copies the binary you just built.

## Usage

### Adding to Layout

1. **View → Layout → Enable Layout Editing Mode**
2. Right-click and choose **Add UI Element**
3. Select **Level Meter**

Layout file names: `level_meter` (also `Level Meter`, `levelmeter`, `vu_meter`, `VU Meter`, `vumeter`, `peak_meter`, `loudness_meter`, `foo_jl_levelmeter`, `jl_levelmeter`).

### Configuration

Access settings in **Preferences > Display > Level Meter**, or right-click the element and choose **Preferences...**.

See [docs/levelmeter.md](../../docs/levelmeter.md) for the full settings reference.

## Project Structure

```
foo_jl_levelmeter_mac/
├── src/
│   ├── Core/
│   │   ├── Detectors.h/cpp            # RMS window, VU needle, PPM rectifiers (pure C++)
│   │   ├── TruePeak.h/cpp             # 4x polyphase true peak detector (pure C++)
│   │   ├── Loudness.h/cpp             # BS.1770 / R128 loudness, gating, loudness range (pure C++)
│   │   ├── StereoStats.h              # Correlation and balance (pure C++)
│   │   ├── MeterEngine.h/cpp          # Runs the detectors, display ballistics, one snapshot per frame (pure C++)
│   │   ├── MeterScale.h/cpp           # dB-to-position mapping, tick labels, VU face geometry (pure C++)
│   │   ├── MeterLayout.h/cpp          # Placement of bars, readouts, figures (pure C++)
│   │   ├── DisplaySettings.h          # Renderer settings and palette (pure C++)
│   │   ├── LevelMeterThemes.h         # Colour theme presets (pure C++)
│   │   └── LevelMeterConfig.h         # Config keys, defaults, configStore accessors and loaders
│   ├── UI/
│   │   ├── MeterRenderer.h/mm         # Digital and analog drawing (no SDK; used by the preview tool)
│   │   ├── LevelMeterView.h/mm        # Flipped view, clicks and context menu
│   │   ├── LevelMeterController.h/mm  # View controller, 60 fps timer, track changes, quit handling
│   │   └── LevelMeterPreferences.h/mm # Preferences page
│   ├── Integration/
│   │   ├── MeterSource.h/cpp          # Sample pull from the visualisation stream (SDK boundary)
│   │   ├── ComponentInfo.h            # Component, layout and preferences names
│   │   └── Main.mm                    # UI element and component registration
│   ├── fb2k_sdk.h                     # SDK configuration
│   └── Prefix.pch                     # Precompiled header
├── Tests/
│   ├── DetectorsTests.cpp
│   ├── TruePeakTests.cpp
│   ├── LoudnessTests.cpp              # Includes the EBU Tech 3341 / 3342 cases
│   ├── MeterEngineTests.cpp
│   ├── MeterScaleTests.cpp
│   ├── MeterLayoutTests.cpp
│   └── TestHarness.h
├── Tools/
│   └── MeterPreview.mm                # PNG renderer behind Scripts/preview.sh
├── Resources/
│   └── Info.plist
├── Scripts/
└── README.md
```

## Technical Details

- Samples come from `visualisation_stream_v2::get_chunk_absolute`; each frame reads the audio played since the previous frame, with a 1 s backlog so loudness misses no audio after a late frame.
- Everything in `src/Core` except `LevelMeterConfig.h` has no SDK or Cocoa dependency and is unit-tested standalone; the tests gate the build.
- `MeterRenderer` needs only Cocoa, so `Scripts/preview.sh` can draw real meter panels (fed by the real engine) to PNG for design checks.
- A 60 fps `NSTimer` drives the view; the meter keeps measuring while its window is covered and stops redrawing once everything has settled.
- An `initquit` service releases all live streams before service teardown; holding a stream through shutdown aborts the app.
- Theme colours are drawn in Display P3 through `shared/ThemeColor.h`.
- Settings persist through `fb2k::configStore` under the `foo_jl_levelmeter.` prefix.

## License

MIT License - see LICENSE file
