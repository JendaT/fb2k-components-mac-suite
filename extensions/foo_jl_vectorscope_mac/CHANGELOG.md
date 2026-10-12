# Changelog

All notable changes to Vectorscope will be documented in this file.

## [0.1.0] - 2026-10-12

Initial release. Contributed by [Scannou](https://github.com/Scannou).

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
