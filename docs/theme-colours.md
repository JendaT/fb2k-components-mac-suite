# Theme colours (Display P3)

The visualisers (Spectrum, Vectorscope, Waveform Seekbar) store theme and custom colours as `0xAARRGGBB` and draw those numbers in **Display P3**, not sRGB. On a wide-gamut screen the same numbers then look more saturated than as sRGB; on an sRGB screen the system maps them back. Stored values were not migrated when this changed (PR #55), so a custom colour picked under sRGB shows a little more saturated now.

## Rules

- Convert with `shared/ThemeColor.h`: `JLColorFromARGB` / `JLARGBFromColor`, for drawing and for colour wells, so a picked colour is what is drawn.
- Bitmaps, gradients and CG fills built from theme colours use `JLCreateThemeColorSpace()` (or `CGContextSetFillColorSpace` with it), not sRGB or device RGB. A theme colour in an sRGB bitmap is clipped to sRGB.
- Mix theme colours in P3 numbers. `-[NSColor blendedColorWithFraction:ofColor:]` may convert to a standard-gamut space first and clip; Spectrum's `blendP3` avoids that.
- Colours built from HSB (complementary hues, rainbow scales) are built in sRGB terms and their numbers read as P3, like the stored colours (Spectrum's `hueColorP3`).
- Waveform draws its fixed overlay and scale palette (readout, badge, ruler, level scale, clip markers) in P3 too, so the whole seekbar shares one look.
- Waveform's `ThemeTokens` derive deep / hot / guide colours in OKLCH with sRGB maths; the view draws the results as P3, so they relate to the accent as before.
