# foo_jl_bpm

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/bpm.md)** | **[Changelog](CHANGELOG.md)**

---

Tempo (BPM) analysis and tagging for foobar2000 macOS. Adds a **BPM** context menu: Analyze BPM..., Double BPM, Halve BPM. Also finds each track's beat grid (bars and phrases) for Waveform Seekbar's phrase markers, using the Beat This! network on Core ML.

## Requirements

- foobar2000 for Mac 2.x
- macOS 12.0+ (Monterey or later)
- Optional: the Tidal component, for TIDAL's tempo on tracks with an ISRC tag

## Quick Start

```bash
# From this directory
./Scripts/build.sh --install            # Run tests, build Release and install
./Scripts/build.sh --clean --install    # Clean rebuild and install
./Scripts/build.sh --regenerate --install  # After adding/removing source files
```

## Build Scripts

| Script | Purpose |
|--------|---------|
| `build.sh` | Run tests, then build (`--debug`, `--release`, `--clean`, `--regenerate`, `--install`) |
| `run_tests.sh` | Compile and run the Core unit tests standalone (`--coverage`) |
| `install.sh` | Install a pre-built component (`--config Debug`) |
| `clean.sh` | Remove build artifacts |
| `generate_xcode_project.rb` | Generate the Xcode project from `src/` |

Never call `xcodebuild` directly; `build.sh` keeps output in the local `build/` directory so `install.sh` copies the binary you just built.

## Project Structure

```
foo_jl_bpm_mac/
├── src/
│   ├── Core/
│   │   ├── TempoEstimator.h/cpp   # Onset envelope + tempo estimation (pure C++, Accelerate)
│   │   ├── BpmValue.h/cpp         # BPM tag parsing, formatting, comparison (pure C++)
│   │   ├── BeatGridAnalyzer.h/cpp # Beat grid: regions, master grid, bars, phrases (pure C++)
│   │   ├── BeatGridStore.h/cpp    # Stored grid blob
│   │   ├── NetworkBeats.h/cpp     # Beat This! chunking and peak picking
│   │   ├── LogMelSpectrogram.h/cpp  # Beat This! front end (matches torchaudio)
│   │   └── ResampleLowpass.h/cpp  # soxr HQ's response at 22.05 kHz
│   ├── Integration/
│   │   ├── Main.mm                # Component registration
│   │   ├── BpmMenu.mm             # BPM context menu
│   │   ├── BpmAnalysis.h/mm       # TIDAL lookup + local analysis in a threaded_process
│   │   ├── BpmJob.h               # Per-track state shared by analysis and review window
│   │   ├── BpmTagWriter.h/mm      # BPM tag writes via metadb_io_v2
│   │   ├── BeatGridService.h/mm   # jl_beatgrid provider: storage, queue, notify
│   │   ├── TrackDecode.h/mm       # One decode: onset envelope + network beats
│   │   ├── BeatThisModel.h/mm     # The bundled model on Core ML
│   │   └── MonoResampler.h/mm     # To 22.05 kHz as soxr resamples
│   └── UI/
│       └── BpmResultsWindowController.h/mm  # Review window
├── Resources/
│   └── BeatThisSmall0.mlpackage   # Beat This! small0, compiled by Xcode at build time
├── Tests/                         # Standalone Core unit tests (run by build.sh)
└── Scripts/
    └── beat_this/                 # Rebuild the model and the front end's test fixture
```

The TIDAL lookup uses the suite-level service declared in `shared/jl_tidal_api.h`, provided by foo_jl_tidal. Without that component everything is analysed locally.

## Beat This!

Beat grids come from Beat This! by Francesco Foscarin, Jan Schlüter and
Gerhard Widmer (Institute of Computational Perception, JKU Linz; "Beat This!
Accurate Beat Tracking Without DBN Postprocessing", ISMIR 2024), the small0
model converted to Core ML (`Scripts/beat_this/`). Where the model cannot run,
the classic onset tracker takes over. Code and weights are under the MIT
license:

```
MIT License

Copyright (c) 2024 Institute of Computational Perception, JKU Linz, Austria

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
