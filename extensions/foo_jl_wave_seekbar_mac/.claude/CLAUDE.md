# foo_wave_seekbar_mac - Claude Code Context

## Project Overview
foobar2000 macOS component displaying audio waveform as interactive seekbar.
**Status:** Feature-complete, code review cleanup done, ready for GitHub.

## Key Files

| Area | File | Purpose |
|------|------|---------|
| Registration | `src/Integration/Main.mm` | Component version, ui_element_mac factory |
| Playback | `src/Integration/PlaybackCallback.mm` | play_callback_static, waveform_init |
| Rendering | `src/UI/WaveformSeekbarView.mm` | Core Graphics, effects, styles |
| Controller | `src/UI/WaveformSeekbarController.mm` | NSViewController, 60fps timer |
| Preferences | `src/UI/WaveformPreferences.mm` | Programmatic UI (FlippedView) |
| Config | `src/Core/ConfigHelper.h` | fb2k::configStore wrapper |
| Service | `src/Core/WaveformService.cpp` | Coordination, listener pattern |
| Cache | `src/Core/WaveformCache.cpp` | SQLite WAL, SHA-256 keys |
| Scanner | `src/Core/WaveformScanner.cpp` | GCD async, input_helper |

## Build Commands
```bash
./Scripts/test_install.sh              # Build + install + test
./Scripts/build.sh --clean --install   # Clean build + install
ruby Scripts/generate_xcode_project.rb # Regenerate Xcode project
open foo_wave_seekbar.xcodeproj        # Open in Xcode
```

## Critical Patterns

**Config persistence:** Use `fb2k::configStore` API via ConfigHelper.h, NOT cfg_var (doesn't persist on macOS v2).

**Settings updates:** Post `NSNotificationCenter` notification "WaveformSeekbarSettingsChanged", view observes and calls `reloadSettings`.

**Memory safety:** Controller owns WaveformData via `std::unique_ptr<WaveformData>` - prevents use-after-free from async callbacks.

**Preferences layout:** Use `FlippedView` subclass with `isFlipped = YES` (macOS coords origin is bottom-left).

**Stereo rendering:** L channel at 75% height, R channel at 25% height, each symmetric from center.

## Features
- 2048 fixed buckets per track (min/max/rms per channel)
- Waveform styles: Solid (gradient bands 0-32), HeatMap, Rainbow
- Cursor effects: None, Gradient, Glow, Scanline, Pulse, Trail, Shimmer
- BPM sync from ID3 tags (BPM/bpm/TBPM/TEMPO fallbacks)
- Click-to-seek, stereo/mono display modes
- SQLite cache with zlib compression

## Install Path
```
~/Library/foobar2000-v2/user-components/foo_jl_wave_seekbar/foo_jl_wave_seekbar.component
```

## Related Resources
- Architecture: `docs/ARCHITECTURE.md`
- Knowledge base: `/Users/jendalen/Projects/Foobar2000/knowledge_base/`
- Plan file: `~/.claude/plans/humming-baking-sutton.md`

## Debug
```bash
pkill -x foobar2000; /Applications/foobar2000.app/Contents/MacOS/foobar2000
```
Shows console::info/error messages in terminal.
