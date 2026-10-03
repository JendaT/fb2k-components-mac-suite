# Changelog

All notable changes to Spectrum Analyzer will be documented in this file.

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
