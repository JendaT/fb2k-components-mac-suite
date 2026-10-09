# Changelog

All notable changes to Spectrum Analyzer will be documented in this file.

## [0.2.0] - 2026-10-09

Contributed by [Scannou](https://github.com/Scannou).

### Added
- **Auto bar count**: One bar per 2 points of panel width, recomputed on resize, orientation and dB-scale changes; up to 2048 bars. New 384 and 512 presets.
- **Per-bar frequency labels**: In Bars mode each bar is labelled with its centre frequency, on one or two staggered rows depending on density.
- **Frequency readout**: Click and hold to show a marker and the exact frequency under the cursor; drag to scrub.
- **Denser frequency axis**: Extra log ticks fill the 10-20 kHz range; linear scale uses round steps; the top label stays inside the plot.

### Changed
- **Settings changes and resizes**: Bars keep their levels (resampled to the new count) instead of blanking.
- **Drawing**: Bars drawn as batched paths with one gradient per frame instead of one per bar; bar edges snap to device pixels with a minimum 1px gap, so narrow bars no longer blur into a moire pattern.

### Fixed
- **Small FFT sizes**: The lowest bands no longer read the DC bin.

## [0.1.0] - 2026-10-03

Initial release. Contributed by [Scannou](https://github.com/Scannou).

### Added
- **Analyzer core**: Real-time FFT bars from the core `visualisation_manager` stream (normalized FFT, mono mix); log or linear frequency mapping rebuilt on sample-rate change; 0..-80 dB display window shared by bars and grid.
- **Dynamics**: Per-bar attack/decay smoothing plus three independent fall timescales: bar, slow-decaying shadow envelope, and peak line with configurable hold.
- **Curve mode**: Smooth monotone curve (no overshoot) spanning the full plot width.
- **Low-end resolution**: Bands narrower than one FFT bin are interpolated at their centre frequency instead of drawing flat steps.
- **Rendering**: Solid / gradient / spectrum bar styles; discrete bars or filled curve; horizontal or vertical orientation; falling peak caps; dim shadow fill; dB scale and logarithmic frequency axis with de-cluttered labels (lowest label kept inside the plot); optional glass background.
- **Preferences** (Preferences > Display > Spectrum Analyzer): bar count up to 256, FFT size, frequency scale and range, smoothing, shadow/peak fall rates, peak hold, grid color and opacity, per-appearance light/dark colors, and 10 color theme presets (Default, Classic, Nord, Dracula, Gruvbox, Solarized, Tokyo Night, Catppuccin, Monokai, Sunset). Live views reload on change.
- **Context menu**: Right-click opens Preferences.
- **Lifecycle**: Visualisation streams released via `initquit` before service teardown (fixes abort on quit); timer guarded against restart during shutdown; stream dropped when the view goes off-screen.
- **Settings persistence**: `configStore`-backed (cfg_var does not persist on macOS v2).
- Universal binary (arm64 + x86_64).
