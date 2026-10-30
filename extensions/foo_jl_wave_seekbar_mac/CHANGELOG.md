# Changelog

All notable changes to Waveform Seekbar will be documented in this file.

## [2.0.0] - 2026-10-30

The redesign and the Display P3 colours were contributed by @Scannou (#49, #55).

![Waveform Seekbar in the Layered style](https://raw.githubusercontent.com/JendaT/fb2k-components-mac-suite/waveform-seekbar-v2.0.0/docs/images/waveform-overview-v3.png)

![Waveform Seekbar in the Classic Solid style](https://raw.githubusercontent.com/JendaT/fb2k-components-mac-suite/waveform-seekbar-v2.0.0/docs/images/waveform-classic-solid.png)

### Added
- **Layered style**: Each channel's peak envelope around its momentary (400 ms) loudness body on a dBFS axis; the gap between them shows the crest factor. Body tint (off, subtle, strong) shades it by the passage's spectral balance.
- **Simple styles**: Two-tone, Glow and Heat draw L and R in lanes on black, on a linear scale, with an RMS core inside the peaks.
- **Split channels**: Third Channels mode for every style: L above and R below one centre line, each at twice a Stereo lane's height.
- **Loudness analysis**: BS.1770-4 integrated loudness, EBU 3342 loudness range, 4x oversampled true peak, PLR, clip runs, correlation and Lo/Mid/Hi energy per track, over every channel (surround weighted, LFE left out).
- **Hover readout**: Time, short-term loudness, peak, crest, correlation and band split under the mouse; beside the mouse or in a corner.
- **Loudness summary**: Integrated loudness, LRA, true peak, PLR and clip count in a badge; off, on hover or always.
- **Clip markers**: Red ticks on the top edge where the audio stays at full scale for 3 or more samples; adjustable brightness.
- **Scales**: Optional time ruler under the waveform and dB level scale on the right.
- **Elapsed time**: Optional m:ss chip beside the playback cursor.
- **Colour themes**: Presets shared with Spectrum Analyzer (P31, P3, P4 and P7 phosphors, Nord, Dracula and more); darker and brighter shades derived in OKLCH.
- **Text size**: One setting for the overlay and scale text.
- **Component details**: A "?" button next to the preferences title shows the component file, version and layout element names, ready to copy.*

### Changed
- **Defaults**: Two-tone in P4 white, level scale, readout and clip markers on, summary on hover, 25 % played-part dimming, no cursor effect; settings that were never changed take them too.
- **Display P3 colours**: Theme and custom colours are drawn in Display P3, so they show at full saturation on wide-gamut screens; stored colours are kept, so they look more saturated than before.
- **Drawing**: Smooth per-pixel-column waveform from cached masks; theme changes recolour without redrawing the shape. The waveform sits 8 pt inside the top and bottom edges.
- **Classic styles**: Solid, Heat map and Rainbow stay as the original styles.
- **Playback cursor**: Drawn in the theme's cursor colour within the waveform area (was a white line over the full height); seeking maps across the waveform area, and the level scale does not seek.
- **Cache**: Stores the fine-grained analysis with the loudness data, so entries are 10-20x larger; every track is analysed again once after the update.
- **Preferences**: Appearance, Scales, Overlays, Played part and Cache cards with a hint under each control; the page scrolls.
- **Parallel analysis**: Long local tracks are analysed in parallel segments on the foobar2000 CPU thread pool (thanks @alies-dev, #40).*
- **Minimum macOS**: Raised to 12.0 (Monterey).*
- **About**: New feature list; shows the layout element name (`waveform-seekbar`) and the preferences path; the copyright notice is replaced by the MIT license line.*
- **Preferences title**: Same size as foobar2000's own page titles.*

### Fixed
- **Played-part dimming**: Matches the background colour exactly; it was rebuilt from device components, a slight shift.
- **Analyzing state**: No longer stuck on "Analyzing..." after a layout change; a 30 s watchdog retries once, then gives up.*
- **Scan cancellation**: Skipping tracks stops the previous track's analysis instead of leaving it running.*
- **Colour drift**: Colours no longer get one step darker on each preferences save and reload.*

### Technical
- One decode pass per track (`TrackAnalyzer`): sample min/max/RMS per block, 100 ms hops of K-weighted power, band power and L*R; parallel segments give a bit-identical result to one pass.
- Cache format v3 (zlib): samples stored up to +6 dBFS, plus the all-channel loudness sum.
- Per-column values are aggregated from the cached blocks (`ColumnAggregator`), so resizing never re-decodes.
- C++ moved under the `waveseek::` namespace; theme colour helpers shared in `shared/ThemeColor.h`.
- 9 unit-test suites gate the build, including exact segment equality, 5.1 loudness, true peak at the track end and cache headroom.

\* Developed as 1.2.1, which was never published.

## [1.2.1] - developed 2026-10-19, never published (ships in 2.0.0)

### Added
- **Component details**: A "?" button next to the preferences title shows the component file, version and layout element names, ready to copy.

### Changed
- **Minimum macOS**: Raised to 12.0 (Monterey).
- **Waveform analysis**: Long tracks decode in parallel segments; a 2 hour MP3 mix is analyzed in ~0.4s instead of ~4s, a 4 minute track in ~0.02s instead of ~0.15s (thanks @alies-dev, #40).
- **About**: Shows the layout element name (`waveform-seekbar`) and the preferences path; the copyright notice is replaced by the MIT license line.
- **Preferences title**: Same size as foobar2000's own page titles.

### Fixed
- **Analyzing state**: The seekbar no longer stays on "Analyzing..." after a layout change; it re-requests the waveform when it reappears, and a 30s watchdog retries once, then gives up.
- **Scan cancellation**: Each scan owns its abort object, so starting a scan no longer clears the abort of the one it replaces (skipping tracks left every earlier decode running); a superseded scan no longer marks the current one finished.
- Colors could drift one step darker each time preferences were saved and reloaded (ARGB conversion truncated instead of rounding)
- `WaveformData` position accessors invoked undefined behaviour on a negative or NaN position; the index is now clamped before the cast

### Technical
- Segments run on the foobar2000 CPU thread pool and seek by absolute sample position, so the result matches a sequential scan exactly; remote, non-seekable and expensive-seek inputs stay sequential, and a segment failure (including a mid-stream sample rate change) falls back to one sequential pass.
- Buckets split the track proportionally; the old fixed bucket size dropped up to 2047 trailing samples.
- Bucket min/max/RMS computed with vDSP; RMS accumulates in double instead of float.
- Peak binning and the segment bucket layout live in `PeakBinner`, so the min/max/RMS math is unit-tested without a decoder or the SDK
- Render geometry and colour ramps extracted into `WaveformGeometry` and `WaveformColorMap`; the four near-duplicate drawing paths in the view collapse to two helpers and `drawRect` only emits Core Graphics calls
- Gradient-band choices now come from one table (`GradientBandTable`) instead of an if/else ladder and a parallel array that could drift apart
- ARGB conversion deduplicated between the view and preferences
- Cache eviction, expiry and key arithmetic extracted into `CachePolicy`, separated from the SQLite statements
- Banded rendering computes each bucket's peak once per trace instead of once per band
- Unit tests (`Tests/`, run by `Scripts/run_tests.sh` under ASan+UBSan) gate the build; ~1s, no SDK or Xcode needed

## [1.2.0] - 2026-07-02

### Added
- Glass background option (Preferences > Display): translucent blur background using the same behind-window effect as SimPlaylist; toggles live without restart
- Background color wells now support transparency (alpha slider in the color panel); a translucent background acts as a tint over the glass blur
- "Preferences..." context menu item that opens the Waveform Seekbar preferences page directly

### Fixed
- Playback cursor updated only ~2x per second on longer tracks; redraw threshold is now pixel-based for smooth movement
- Animated cursor effects (Glow, Scanline, Pulse, Shimmer) now animate continuously instead of only on cursor movement
- Played-portion shading painted the opaque background color over the glass blur; it now uses a neutral translucent dim in glass mode
- Stale waveform scans no longer overwrite the current track's data on rapid track changes (generation counter)
- Race between concurrent cache store and lookup resolved (double-check under lock)
- Per-controller waveform listener removal; seekbar recovers cleanly when layout elements are recreated

### Technical
- SQLite cache uses prepared statements for all queries
- Construct-on-first-use singletons avoid static initialization order issues
- Listener callbacks invoked outside the lock to prevent deadlocks
- Position updates driven solely by the 60fps timer; removed redundant playback-time dispatch and verbose config logging

## [1.1.0] - 2025-12-29

### Added
- Context menu with right-click on waveform seekbar
- "Lock Width" option to prevent horizontal resizing
- "Lock Height" option to prevent vertical resizing
- Lock settings persist across application restarts

## [1.0.0] - 2025-12-28

### Added
- Initial release
- Complete waveform display with 2048 buckets per track
- Click-to-seek functionality
- Stereo and mono display modes
- Waveform styles: Solid (with gradient bands), HeatMap, Rainbow
- Cursor effects: None, Gradient, Glow, Scanline, Pulse, Trail, Shimmer
- BPM sync for cursor animations from ID3 tags
- Dark mode support with automatic appearance switching
- SQLite waveform cache with zlib compression
- Configurable cache size and retention
- Preferences panel for all settings
