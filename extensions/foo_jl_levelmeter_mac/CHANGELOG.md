# Changelog

All notable changes to Level Meter will be documented in this file.

## [Unreleased]

### Fixed
- **Non-finite samples**: A NaN or infinite sample is read as silence, so it can no longer freeze the needle, correlation, balance and loudness until foobar2000 restarts.
- **Clip light at full scale**: Samples that reach exactly 0 dBFS light the clip light, so clipped PCM shows in sample-peak mode.

## [0.1.0] - 2026-11-17

First release, contributed by @Scannou (#56).

### Added
- **Level meter**: Peak, RMS, loudness and VU in one panel. Layout element `level_meter`.
- **Digital bars**: RMS as the wide bar with the peak as a slim column above it, peak hold, latching clip lights and max peak readouts; click the bars to reset.
- **Peak modes and scales**: True peak (4x oversampled) or sample peak; dBFS or K-20 / K-14 / K-12, extended-top or linear spacing, range -24 to -120 dB; optional LED segments.
- **Loudness**: BS.1770 / EBU R128 momentary and short-term bars, gated integrated loudness, loudness range, true peak max and PLR, with a target marker (-9 to -24 LUFS); optional reset on track change.
- **Stereo**: Phase correlation and balance bars, each with its own switch.
- **Analog VU**: Backlit needle faces (Vintage, Dark or theme colours), two faces or one with two needles; VU or DIN / BBC / Nordic PPM ballistics, reference level and peak LED.
- **Layout**: Vertical, horizontal or automatic; extras drop out in a fixed order on small panels; text size Small to Extra large.
- **Colours**: Themes shared with the other visualisers, light and dark colours, glass background; drawn in Display P3.
- **Preferences**: Display > Level Meter, in cards (Display, Appearance, Show, Levels, Loudness, Analog); settings that don't apply to the chosen style are hidden.
- **Context menu**: Reset Peaks, Reset Loudness, Digital / Analog VU, Preferences.
- **Component details**: A "?" button next to the preferences title shows the component file, version and layout element names, ready to copy.
