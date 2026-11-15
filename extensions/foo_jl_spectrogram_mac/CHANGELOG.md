# Changelog

All notable changes to Spectrogram will be documented in this file.

## [0.1.0] - 2026-11-09

First release, contributed by @Scannou (#45).

### Added
- **Scrolling spectrogram**: Frequency over time, level as colour; the picture holds on pause and stop. Layout element `spectrogram`.
- **Reassigned analysis** (default): Short windows with frequency reassignment keep tonal lines thin, bass included, while kicks stay narrow in time; the standard spectrum shows 18 dB down underneath.
- **Multi-resolution and Standard modes**: Longer windows for bass and shorter ones for treble, or one window everywhere.
- **Levels in dBFS**: A full-scale sine reads 0 dB in every mode; top level, dB range and slope are adjustable.
- **Analysis settings**: FFT size 1024 to 16384, Hann or Blackman-Harris window; channel Mid, Left, Right or Side.
- **Frequency scale**: Logarithmic, mel or linear, with an adjustable range (default 20 Hz to 20 kHz).
- **Orientation**: Vertical or horizontal, with reversible scroll direction; the same setting as the Spectrum Analyzer lines up both panels' frequency axes.
- **Full screen**: Double-click or the context menu opens a native full-screen Space with its own orientation setting; Esc or double-click exits.
- **Colours**: Nine colormaps, one ramp per Spectrum Analyzer theme, and a custom four-colour ramp; panel background and grid colours for light and dark appearance.
- **Axis and readout**: Frequency labels and a dB colour scale with adjustable font sizes and gridlines; click and hold for the frequency and nearest note under the cursor.
- **Context menu**: Full Screen, Freeze, Clear and Preferences.
- **Component details**: A "?" button next to the preferences title shows the component file, version and layout element names, ready to copy.
