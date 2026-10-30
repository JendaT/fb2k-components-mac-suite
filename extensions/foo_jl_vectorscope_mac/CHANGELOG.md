# Changelog

All notable changes to Vectorscope will be documented in this file.

## [1.1.0] - 2026-10-30

Display P3 colors contributed by @Scannou (#55).

### Changed
- **Display P3 colors**: Theme and custom colors are drawn in Display P3, so they show at full saturation on wide-gamut screens; stored colors are kept, so they look more saturated than before.
- **Afterglow trace**: Built in P3, so it keeps the theme's saturation; the grid and correlation bars follow.
- **Color wells**: Read and write P3, so a picked color is what is drawn.

### Technical
- Theme color helpers shared in `shared/ThemeColor.h`; the rules are in `docs/theme-colours.md`.

## [1.0.0] - 2026-10-20

Contributed by @Scannou, apart from the Component details, About and Preferences title entries.

### Added
- **Phosphor themes**: P31 green, P3 amber, P4 white and P7 blue, listed first; theme names and colors match the Spectrum Analyzer.
- **Component details**: A "?" button next to the preferences title shows the component file, version and layout element names, ready to copy.

### Changed
- **Themes**: "Default (Phosphor Green)" is now "Classic (Green)", "Blue" is "Default (Blue)", and Amber gives way to P3 amber; the selector shows the preset matching the current colors, so edited colors read as Custom.
- **Defaults**: P4 white with a band-colored trace and a band correlation meter on the right; afterglow 101 ms, brightness 74%, bar thickness 12 pt, response time 284 ms, low crossover 160 Hz, grid opacity 32%; settings that were never changed take them too.
- **About**: Shows the layout element name (`vectorscope`) and the preferences path; the copyright notice is replaced by the MIT license line.
- **Preferences title**: Same size as foobar2000's own page titles.

## [0.1.0] - 2026-10-12

Initial release. Contributed by @Scannou.

### Added
- **Scope**: Goniometer (mid up, side across) or Lissajous (left across, right up) style; full-scale outline, dashed -6 dB and -12 dB guides, mid/side and left/right axes with L / R / M / S labels.
- **Trace**: Oscilloscope-style afterglow drawn as lines or dots, with adjustable persistence and brightness; dot size Auto or 1-8 pt.
- **Band colors**: Optional low / mid / high split of the trace, each band in its own color.
- **Gain**: Auto gain (drops at once on level jumps, rises gently, keeps the trace inside the outline) or fixed 0 to +36 dB.
- **Correlation meter**: Broadband or low / mid / high bars with adjustable crossovers; position Auto, Bottom, Top, Left or Right; adjustable bar thickness; recent-range band with adjustable hold; hides when the panel is too small.
- **Appearance**: 11 color presets for light and dark appearance, every color editable, optional glass background.
- **Preferences** (Preferences > Display > Vectorscope) apply live; right-click opens them.
- **Lifecycle**: Visualisation stream released before service teardown at quit, and when the panel goes off-screen.
- Universal binary (arm64 + x86_64).
