# foo_jl_bpm

> Part of [foobar2000 macOS Components Suite](../../README.md)

**[Features & Documentation](../../docs/bpm.md)** | **[Changelog](CHANGELOG.md)**

---

Tempo (BPM) analysis and tagging for foobar2000 macOS. Adds a **BPM** context menu: Analyze BPM..., Double BPM, Halve BPM.

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
│   │   └── BpmValue.h/cpp         # BPM tag parsing, formatting, comparison (pure C++)
│   ├── Integration/
│   │   ├── Main.mm                # Component registration
│   │   ├── BpmMenu.mm             # BPM context menu
│   │   ├── BpmAnalysis.h/mm       # TIDAL lookup + local analysis in a threaded_process
│   │   ├── BpmJob.h               # Per-track state shared by analysis and review window
│   │   └── BpmTagWriter.h/mm      # BPM tag writes via metadb_io_v2
│   └── UI/
│       └── BpmResultsWindowController.h/mm  # Review window
├── Tests/                         # Standalone Core unit tests (run by build.sh)
└── Scripts/
```

The TIDAL lookup uses the suite-level service declared in `shared/jl_tidal_api.h`, provided by foo_jl_tidal. Without that component everything is analysed locally.
