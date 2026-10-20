# Changelog

All notable changes to Spectrum Analyzer will be documented in this file.

## [1.0.0] - 2026-10-20

Contributed by [Scannou](https://github.com/Scannou), apart from the Component details, About and Preferences title entries.

### Added
- **Own FFT**: Analyses PCM from the visualisation stream with its own vDSP FFT (Blackman-Harris or Hann window, 1024-32768); steep roll-offs such as a CD master's cut-off show as a cliff instead of a leakage floor.
- **Mid + side**: Stereo setting that adds the side channel as a second line in the complementary hue.
- **Curve detail**: Full detail or 1/24 to 1/3 octave smoothing; Curve mode draws one point per point of panel width.
- **Top and Range**: Fixed dB window; Top 0 to -60 dB, Range 60, 80, 90 or 120 dB.
- **Hover readout**: Crosshair with frequency, nearest note with cents, and level; replaces click and hold.
- **Presets**: Default, Classic bars, RTA 1/3 octave, Fine detail and Mid + side.
- **Phosphor themes**: P31 green, P3 amber, P4 white and P7 blue, listed first.
- **Legend**: Optional Live / Peak hold key in Curve mode.
- **Component details**: A "?" button next to the preferences title shows the component file, version and layout element names, ready to copy.

### Changed
- **Defaults**: Curve with line and color bars, P3 amber, 90 dB range, FFT 2048, compact-bass log scale, RMS averaging at 255 ms, 1.0 dB/oct slope; settings that were never changed take them too.
- **Peak line**: Holds 920 ms, then falls at a steady 12 dB/s (setting now in dB/s); 0.3.0 values convert.
- **RMS averaging**: Own Averaging time setting (0-500 ms); 0.3.0 values carry over.
- **Frequency labels**: More labels (2x and 5x, then 3x, 4x, 6x and 8x) where they fit; decades bolder.
- **Preferences**: Display, Analysis, Motion and Appearance sections; rows that do not apply are hidden or say why they are disabled; the page scrolls.
- **About**: Shows the layout element name (`spectrum`) and the preferences path; the copyright notice is replaced by the MIT license line.
- **Preferences title**: Same size as foobar2000's own page titles.

### Fixed
- **Drawing exceptions**: A nil font or color can no longer throw inside drawing and crash foobar2000 later.
- **Low sample rates**: Grid, labels and readout stop at half the sample rate, like the spectrum.
- **Bar edges**: Wide bars read the FFT bins whose centre lies inside them, not the bin below.

## [0.3.0] - 2026-10-12

Contributed by [Scannou](https://github.com/Scannou).

### Added
- **Full-screen view**: Double-click the panel, or choose Full Screen from its context menu, to open the spectrum in a native full-screen Space; Esc, double-click or Exit Full Screen leaves it.
- **Logarithmic (compact bass) scale**: Maps frequency as log10(1 + f/50), so the bottom octaves take far less width than on a pure log axis.
- **RMS averaging**: New Smoothing mode that averages signal power per FFT bin over 0-200 ms, so levels rise and fall at one even rate like a real-time analyzer.
- **Spectral slope**: Tilts the display 0-6 dB/octave around 1 kHz so high frequencies read higher.
- **Curve styles**: Filled, Line, Color bars, and Line + color bars for the Curve draw mode, with adjustable color bar brightness.

### Changed
- **Display-synced redraw**: On macOS 14+ the spectrum updates in step with the screen refresh (60-90 fps on fast displays) instead of a free-running 60 Hz timer; macOS 12-13 keep the timer.
- **Frame-rate independent motion**: Smoothing, shadow fall, peak hold and peak fall scale with elapsed time, so motion looks the same at any refresh rate.
- **Covered panels**: A panel whose window is fully covered (e.g. by the full-screen view) skips redrawing.

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
