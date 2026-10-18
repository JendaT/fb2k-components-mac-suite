# Waveform Seekbar: redesign spec

Reference material in this folder:
- `renders/`: PNG renders at 2x. A_layered, E_simple_amber/blue, F_prefs_* (preferences with live preview: Layered + hover, Glow + hover, Heat/blue with everything off).
- `source/`: the mockup HTML. Serve it over HTTP (`cd source && python3 -m http.server`), because CSS masks don't load from file://. F_Preferences.html is interactive: hover shows the readout, click seeks, and the prefs controls work.
- The audio data in the mockups is synthetic. Numbers are illustrative; the layout, colours and behaviour are the spec.

This replaces the current "Scale: Loudness / Peak" setting. Keep the existing per-pixel column rendering and the per-track image cache. They still apply.

---

## 1. Analysis: one pass per track, cached

Analyse once at a fixed block resolution and cache the block arrays. Per-column values are aggregated from blocks at draw time, so a resize never re-decodes.

Per block (~1024 samples, or 100 ms hop for the loudness gates):
- Sample min/max per channel (Simple styles)
- RMS per channel
- K-weighted mean square per channel (BS.1770), for momentary (400 ms) and short-term (3 s) loudness
- Band energies Lo / Mid / Hi. Use the same crossovers as the Vectorscope's tri-band correlation meter.
- Stereo correlation terms: ΣLR, ΣL², ΣR²
- Clip runs: ≥3 consecutive samples at full scale (|x| ≥ 0.9999 for float sources)

Per-track summary:
- Integrated loudness: BS.1770-4 gating (absolute −70 LUFS, relative −10 LU)
- LRA: EBU Tech 3342 (short-term 3 s, absolute −70, relative −20, 10th–95th percentile)
- True peak: 4× oversampled, dBTP
- PLR = TP − I
- Clip-run count

Cache key: path + size + mtime (+ subsong).

Per-column arrays for the hover readout: LUFS-S, max sample peak (dBFS), crest (peak − RMS, dB), correlation, Lo/Mid/Hi energy share (%).

---

## 2. Colours and theming

Every style draws its colours from the player theme. Each theme provides three tokens:

| token | amber | blue |
|---|---|---|
| accent | #E8B547 | #8C9EEB |
| deep | #7A4A12 | #2E3A8C |
| hot | #FFF2C8 | #EEF1FF |

If a theme only defines `accent`, derive `deep` and `hot` in OKLCH and keep the hue. Deep: lower lightness, slightly less chroma. Hot: lightness about 0.95, low chroma. Don't derive them in RGB.

Rendering model: cache the waveform layers as **alpha masks** per (track, width, height, style family). Apply colour at draw time with clip-to-mask, then a fill or gradient (`CGContextClipToMask` + `CGContextDrawLinearGradient`). A theme or style change is then a redraw, not a re-analysis.

Played and unplayed: draw the same masks twice under two clip rects. Played is at full opacity; unplayed is at `unplayedOpacity` (default 0.5). 60 fps updates only redraw the played/unplayed boundary, the cursor and the overlays.

Cursor: 1 px #F5EFE2 line, plus a time chip (m:ss, bold, #F5EFE2 background, dark text) 4 px right of the line at top 4 px.

---

## 3. Style A: Layered (default)

See `renders/A_layered.png`.
- Background: theme dark (mock #13110C).
- Mirrored: L up, R down. One dBFS axis, floor −36 dB.
  `h = clamp((dB − floor) / (0 − floor), 0, 1) × (halfHeight − 2px)`
- Peak layer: column fill = accent at 26 % alpha, plus a 1 px edge line at 55 % alpha.
- Loudness body: K-weighted short-term level per column, solid accent.
- The gap between the two layers is the crest factor, so compression is visible.
- Gridlines at −12 and −24 dB in each half (#211D15). Centre line #3A3326. Silence shows as the centre line only.
- Later: floor setting −24 / −36 / −48 / Auto, where Auto = the track's 5th percentile of short-term loudness.

## 4. Style E: Simple (black background)

See `renders/E_simple_*.png`. There are three variants, all selectable in preferences.
- Background #000. Two separate lanes: L on top, R below, each with its own centre line (accent mixed 85 % toward black), 2 px gap between them.
- **Linear** amplitude, not dB. Peak layer = per-column sample min/max. RMS core = RMS × √2 (otherwise it's a sliver), drawn in the same lane.
- Gradients are vertical and **mirrored around each lane's own centre line**.

| variant | peak layer | RMS layer |
|---|---|---|
| Two-tone (Bitwig-like) | flat: accent mixed 50 % with black | flat: accent |
| Glow | gradient edge → mid → centre: accent mixed with black at 0.82 → 0.55 → 0.20 | gradient edge/mid = accent, centre = hot |
| Heat | gradient centre = deep, mid = accent, tips = hot | not drawn |

---

## 5. Overlays (all styles)

- **Hover readout.** Tooltip 186 px wide, top 10 px, 10 px right of the mouse X. It flips to the left side when within 210 px of the right edge. A 1 px dashed vertical line marks the mouse position, and clicking seeks there.
  - Header: time `m:ss.s`, plus the hint "click to seek".
  - Rows: LUFS-S, Peak (dBFS), Crest (dB), Corr (signed, 2 dp).
  - A 4 px stacked Lo/Mid/Hi bar with percentages below it.
  - Style: background rgba(19,17,12,0.95), 1 px #3A3326 border, radius 4. Values #F2E9D6, labels #9A907D.
- **Loudness summary badge.** Bottom-right, 6 px inset: `I −12.4 LUFS · LRA 15.9 LU · TP +0.4 dBTP · PLR 12.8 · 17 clips`.
  - TP is shown in #F0603F when above 0. The clip count is shown only when > 0, in #F0603F.
  - Modes: Off / On hover / Always. Default: On hover.
- **Clip markers.** 2 × 5 px #F0603F ticks on the top edge, one per clip run.
- Use the Unicode minus (−), not a hyphen, in all numbers.
- Typography: SF Mono 10 px for overlays and scales (labels #8A8170), the system font in preferences.
- Band colours: Lo #C7772A, Mid #D9C26A, Hi #A8D4F2.

## 6. Scales (each one optional)

- **Time ruler.** 22 px strip under the waveform, with a 1 px top border #2C271D.
  - Minor ticks are 4 px, major ticks 8 px, with labels `m:00` 3 px right of the major tick.
  - Pick the major interval from {10 s, 15 s, 30 s, 1 m, 2 m, 5 m, 10 m} so labels are ≥ ~110 px apart. Minor ticks go at major/4.
- **Level scale.** 48 px gutter on the right.
  - Layered: 0 / −12 / −24 / −∞ mirrored, with a "dBFS" unit label.
  - Simple: per lane 0 / −6 / −∞ / −6 (−6 dB = half amplitude), with L/R labels.
  - When this is off, the waveform takes the full width.

## 7. Preferences

| key | type | default | notes |
|---|---|---|---|
| style | enum: layered, simple_two_tone, simple_glow, simple_heat | layered | |
| unplayed_opacity | float 0.2–1.0 | 0.5 | |
| hover_readout | bool | true | |
| loudness_summary | enum: off, hover, always | hover | |
| clip_markers | bool | true | |
| time_ruler | bool | true | |
| level_scale | bool | true | |

Colours come from the player theme; there is no separate seekbar colour setting. The layout of the preferences page is in `renders/F_prefs_*.png`: three cards (Appearance / Overlays / Scales), each control with a one-line hint.

## Out of scope for now

Mockups B (tri-band), C (spectral tint) and D (analysis lanes, including a spectrogram strip) are not part of this change.
