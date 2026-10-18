# Spectrum Analyzer

A real-time spectrum analyzer UI element for foobar2000 macOS. Contributed by [Scannou](https://github.com/Scannou).

## Features

### Real-Time FFT Bars

Frequency bars driven by PCM from the core `visualisation_manager` stream, updated once per display frame. The component runs its own FFT (Apple vDSP, Hann or Blackman-Harris window) and maps it into a configurable number of bars over a dB window set by Top and Range (default 0 dB to -80 dB). A full-scale sine reads 0 dB. Both windows' far sidelobes fall away fast, so steep roll-offs (e.g. a CD master's cut-off just below 20 kHz) show as a cliff instead of a leakage floor; the core's own spectrum uses a Gauss window, which leaves a floor only 45-70 dB below the music.

At the low end, where several log-scale bands fall inside a single FFT bin, each band is sampled at its centre frequency, interpolated in dB along a monotone cubic through the neighbouring bins (Steffen's tangents), instead of reading the same bin as flat steps. The cubic rounds the corners the coarse bin spacing of the bass would otherwise show, and never overshoots a bin's level.

### Draw Modes

| Mode | Description |
|------|-------------|
| **Bars** | Discrete frequency bars with configurable gap and fill style |
| **Curve** | Smooth curve spanning the full plot width, in one of four curve styles; always drawn at full resolution (one point per point of panel width, up to 2048), so the Bars setting does not apply. **Curve detail** sets how much of the FFT's detail it shows. The live curve is the strong line; the peak line is a thinner, fainter line in the same colour, and a small **Live / Peak hold** legend names them (**Show legend** hides it) |

**Curve detail** (Curve mode only) sets how much of the FFT's detail the curve shows. **Full** draws every FFT bin. **1/24** (the default, close to studio analyzers), **1/12**, **1/6** or **1/3 octave** averages the signal power over that fraction of an octave around each point (fractional-octave smoothing, as measurement analyzers offer), for a calmer curve with less detail; the peak and side lines follow it. At the low end, where the window is narrower than an FFT bin, the curve keeps reading the bins directly and blends into the average as the window widens.

The curve uses monotone cubic interpolation (Steffen), so it never overshoots between bands: peaks stay where the data puts them and the curve stays inside the 0..1 range.

![Spectrum Analyzer in bars mode](images/spectrum-bars.png)

### Curve Styles

Curve mode can be drawn four ways:

| Style | Description |
|-------|-------------|
| **Filled** | Stroked line over a gradient-filled area |
| **Line** | Stroked line only |
| **Color bars** | Stripes over the full height of the plot, more opaque where a frequency is louder; no line |
| **Line + color bars** | Stroked line, with the stripes filling only the area under it |

Color bars use the theme colour, with each stripe's strength following the square of its level (as on MiniMeters), so dominant frequencies stand out at a glance while mid-level bands stay visible. **Color bar brightness** sets how strong the loudest stripe gets. The shadow fill is not drawn in the two color-bar styles, and the peak line is not drawn in **Color bars**.

Filled:

![Spectrum Analyzer in curve mode, filled style](images/spectrum-overview.png)

Line + color bars:

![Spectrum Analyzer in curve mode with color bars](images/spectrum-curve.png)

### Frequency Scales

| Scale | Description |
|-------|-------------|
| **Logarithmic** | Equal width per octave |
| **Linear** | Equal width per Hz |
| **Logarithmic (compact bass)** | `log10(1 + f/50)`: logarithmic in the highs and close to linear below about 50 Hz, so the bottom octaves take far less width than on a pure log axis |

Bars, gridlines, labels and the frequency readout all follow the selected scale.

### Smoothing Modes

| Mode | Description |
|------|-------------|
| **Attack / decay** | Fast rise and slower fall, applied to the displayed dB value |
| **RMS average** | Running average of signal power per FFT bin; levels rise and fall at one even rate, like a real-time analyzer |

In **RMS average** the Smoothing slider sets the averaging time (0-500 ms, in 5 ms steps) and its label shows milliseconds. Each mode keeps its own Smoothing value, so switching modes does not carry an amount over that means something else in the other mode. Settings from 0.3.0, where RMS used the shared value at 2 ms per step, carry over until the slider is moved.

### Spectral Slope

**Slope** tilts the displayed spectrum around 1 kHz by 0 to 6 dB per octave, so high frequencies read higher and bass lower. Music usually falls off towards the highs; a slope flattens the display so detail there is easier to see. The dB scale then shows sloped levels, not true ones.

### Level Range

The display shows a fixed dB window, as pro analyzers do: there is no auto gain, so a level always sits at the same height. **Top** sets the level at the top of the display (0 to -60 dB); lower it to fill the height with quiet music. **Range** sets the span down to the bottom: 60, 80, 90 or 120 dB. The dB scale follows both, with a guide every 10 dB (every 20 dB at 120 dB range).

### Full Screen

Double-click the panel, or right-click and choose **Full Screen**, to open the spectrum in its own full-screen Space on the same display. It uses the same settings as the panel. Leave with Esc, a double-click, or **Exit Full Screen** in the context menu. The panel pauses while it is fully covered.

### Orientation

Horizontal (frequency along X, magnitude grows up) or vertical (frequency along Y, magnitude grows sideways). The dB scale and frequency axis follow the orientation.

### Three-Layer Dynamics

Each bar has three layers that rise instantly and fall at different rates:

| Layer | Behavior |
|-------|----------|
| **Bar** | Current level, smoothed by the selected smoothing mode |
| **Shadow** | Dim fill behind the bar that eases down at a steady medium rate; in RMS average its fall is scaled to the curve's own fall rate, so it always trails the curve |
| **Peak** | Thin cap that holds for a configurable time, then falls at a steady dB/s rate |

The peak line is the highest of every recent level, each held for the hold time and then falling at the peak fall rate. A level that arrives during another's hold is kept, not forgotten, so neighbouring bands fall together and the line stays as smooth across frequency as the curve.

### Mid + Side

**Stereo: Mid + side** adds the side channel, (L - R) / 2, as a second line in the bar color's complementary hue. The main curve is always the mid channel, (L + R) / 2. Mono content leaves the side line at the bottom; wide content brings it up towards the mid curve.

By default the curve uses RMS averaging at 270 ms (falling up to about 16 dB/s), and the peak line holds for 920 ms and then falls 12 dB/s. For reference, real-time analyzers commonly use the IEC 61672 "Fast" time weighting (125 ms, up to about 35 dB/s), and digital peak meters return 20 dB in 1.7 s (about 12 dB/s, IEC 60268-18). The curve shows what is playing now; the peak line above it shows how loud each band just was. Peak fall settings from 0.3.0 (a 0-100 accelerating speed) convert to the steady rate that covers the first 20 dB in the same time.

### Bar Styles

| Style | Description |
|-------|-------------|
| **Solid** | Single bar color |
| **Gradient** | Vertical gradient from a darkened to a lightened bar color |
| **Spectrum** | Hue mapped across frequency (low to high) |

### Grid

- **dB scale**: guide lines every 10 dB (20 dB at 120 dB range), labelled with numbers only (the top line names the unit), positioned against the same Top / Range window the bars use; the top label always stays whole, sitting just below the top line
- **Frequency axis**: on both logarithmic scales, gridlines at 1..9 x 10^n Hz; decades (100 Hz, 1 kHz, 10 kHz) are drawn at 70% of the grid opacity, the lines between at 45%. Only 1-2-5 values are labelled, decades bolder and brighter, in a monospaced font; the linear scale uses round steps
- **Labels** take the background colour blended 70% towards white (or black on light backgrounds), so they stay readable with a theme's deliberately dim grid
- **Per-bar labels**: in Bars mode each bar is labelled with its centre frequency, on one or two staggered rows depending on density
- Both auto-hide when the view is too small; color and opacity are configurable (0% hides the grid)

### Color Themes

Fourteen presets stamp level, background, and grid colors for both light and dark appearance at once. Four are named after CRT phosphors, one colour each with a near-black background tinted towards it and a pale grid: P31 green, P3 amber, P4 white and P7 blue (the default). They are listed first; the others are Default (Blue), Classic (Green), Nord, Dracula, Gruvbox, Solarized, Tokyo Night, Catppuccin, Monokai and Sunset. Editing any color well switches the theme selector to Custom.

### Glass Background

Optional translucent behind-window blur instead of a solid background color (same effect as SimPlaylist and Waveform Seekbar).

### Frequency Readout

Hover over the plot to read the spectrum under the mouse: a dashed crosshair through the live curve, a dot on it, and a box with the frequency, the nearest note with its offset in cents, and the level in dB. In Curve mode the frequency is also marked on the axis.

### Dark Mode Support

Separate bar, background, and grid colors for light and dark appearance; the view redraws on appearance change.

## Configuration

Access settings via **Preferences > Display > Spectrum Analyzer**, or right-click the element and choose **Preferences...**. Changes apply live. The page is laid out like P31 Spectrum's settings page: settings that do not apply to the current ones are hidden (for example the Bars rows in Curve mode), or disabled with a note saying why. It scrolls when the preferences window is shorter than the page.

![Spectrum Settings](images/spectrum-settings.png)

### Presets

**Preset** replaces every setting, colors included, with a factory preset (the Glass background setting is left alone):

| Preset | Description |
|--------|-------------|
| **Default** | All defaults |
| **Classic bars** | 48 bars, attack / decay smoothing at 60, logarithmic scale |
| **RTA, 1/3 octave** | Filled curve at 1/3-octave detail, logarithmic scale, FFT 8192, 500 ms averaging |
| **Fine detail** | Line at full detail, FFT 16384, Blackman-Harris window, logarithmic scale, 120 dB range |
| **Mid + side** | Mid + side lines at 1/12-octave detail |

### Display

| Setting | Description | Range | Default |
|---------|-------------|-------|---------|
| Draw mode | Curve or Bars | Curve, Bars | Curve |
| Curve style | Curve mode only | Filled, Line, Color bars, Line + color bars | Line + color bars |
| Curve detail | Curve mode only: Full draws every FFT bin, an octave fraction averages power over that band around each point | Full, 1/24, 1/12, 1/6, 1/3 octave | 1/24 octave |
| Color bar brightness | Strength of the loudest color bar (Curve mode; color-bar styles only) | 10-100% | 85% |
| Bars | Bars mode only; Auto draws one bar per 2 points of panel width (up to 2048) | Auto, 16-512 | 96 |
| Bar style | Bars mode only | Solid, Gradient, Spectrum | Gradient |
| Bar gap | Bars mode only, % of slot width | 0-80% | 2% |
| Orientation | | Horizontal, Vertical | Horizontal |
| Top | Level at the top of the display | 0 to -60 dB | 0 dB |
| Range | dB from the top of the display to the bottom | 60, 80, 90, 120 dB | 80 dB |
| Show peaks | Peak caps in Bars mode, a peak line in Curve mode | | On |
| Shadow fill | Dim, slow-falling fill behind the levels; not drawn (and disabled) in the color-bar styles | | On |
| Show dB scale | dB guide lines and labels | | On |
| Show frequency axis | Frequency gridlines and labels | | On |
| Show legend | Curve mode only: the Live / Peak hold key in the plot's top-left corner | | On |

### Analysis

| Setting | Description | Range | Default |
|---------|-------------|-------|---------|
| FFT size | Larger sizes resolve low frequencies better but react more slowly | 1024-32768 | 2048 |
| Window | Blackman-Harris keeps loud tones from spilling into quiet neighbours, at the cost of wider peaks | Hann, Blackman-Harris | Hann |
| Stereo | Mono, or Mid + side (side channel as a second line) | Mono, Mid + side | Mono |
| Frequency scale | Band mapping | Logarithmic, Linear, Logarithmic (compact bass) | Logarithmic (compact bass) |
| Lowest / Highest frequency | Displayed range; the top is limited to half the sample rate | 10-2000 / 1000-24000 Hz | 20 / 20000 Hz |
| Slope | Tilt around 1 kHz, in 0.1 steps | 0-6 dB/octave | 2.0 |

### Motion

| Setting | Description | Range | Default |
|---------|-------------|-------|---------|
| Smoothing mode | How levels are smoothed over time | Attack / decay, RMS average | RMS average |
| Smoothing | Attack / decay only (higher = smoother) | 0-100 | 82 |
| Averaging time | RMS average only, in 5 ms steps | 0-500 ms | 270 ms |
| Shadow fall | How fast the shadow falls; disabled while the shadow is not drawn | 0-100 | 76 |
| Peak fall | How fast peaks fall after their hold; disabled while peaks are off | 1-60 dB/s | 12 dB/s |
| Peak hold | How long a peak stays before it falls; disabled while peaks are off | 0-2000 ms | 920 ms |

### Appearance

| Setting | Description | Default |
|---------|-------------|---------|
| Theme | Color preset (Custom + 14 presets, phosphors first) | P7 blue |
| Grid opacity | Grid line opacity (0% hides the grid) | 60% |
| Levels / Background / Grid | Light and dark color for each | P7 blue colors |
| Glass background | Translucent blur instead of solid color | Off |

## Layout Editor

Add Spectrum Analyzer to your layout using any of these names:
- `spectrum` (recommended)
- `Spectrum Analyzer`
- `spectrum_analyzer`
- `foo_jl_spectrum`
- `jl_spectrum`

Example layout:
```
splitter vertical
  waveform-seekbar
  spectrum
  simplaylist
```

## Technical Details

### Audio Analysis

- `visualisation_stream_v2::get_chunk_absolute` with a 1 s backlog (room for a centred 32768-sample frame), all channels; one FFT-size frame centred on the playback position (falling back to the frame ending or starting there right after a start or seek)
- Mid is the channel average, side half the difference of the first two channels; each gets the analysis window (periodic Hann, or 4-term Blackman-Harris) and a vDSP real FFT, scaled by `1 / sum(window)` so a full-scale sine reads 1.0
- Band edges recomputed when the stream's sample rate changes; the DC bin is skipped
- Peak magnitude across each band's bins (reads punchier than the average)
- RMS average keeps a one-pole average of power for every FFT bin and reads the bars off the averaged spectrum. With nothing coming in, the curve falls at most `10 x log10(e) / tau` dB/s (about 16 dB/s at 270 ms); the shadow fall slider maps to 15-90% of that rate
- Bar height is `(dB - (Top - Range)) / Range`, clamped to 0..1; peak fall and the RMS shadow fall are converted to height per frame against the current Range, so their dB/s rates hold at any range
- The slope is a per-bar gain of `slope x log2(f / 1 kHz)` dB at the bar's centre frequency
- Rates for smoothing, shadow fall, peak fall, and peak hold are defined per 1/60 s and scaled by the time since the previous update, so motion is the same at any refresh rate

### Rendering

- Core Graphics (Quartz 2D), layer-backed view
- On macOS 14 and later, updates come from the view's `CADisplayLink`, in step with the screen's refresh; on fast displays every second or third refresh is used (60-90 fps). macOS 12-13 uses a 60 fps `NSTimer` on the main run loop (common modes)
- Redraws only while audio is live or bars are still settling, and not while the window is fully covered
- Color bars are a single gradient along the frequency axis with a stop at each band centre
- The plot and its labels run edge to edge, with no margin around the panel; a dB label on the very top line sits just below it so it stays whole
- Stream released when the view goes off-screen; recreated lazily on the next tick (a fresh stream returns no data for its first reads, so it is not released per idle frame)

### Lifecycle

- An `initquit` service stops every live view's updates and releases its stream before the core tears down the visualisation backend; holding a stream through shutdown throws `exception_service_not_found` and aborts
- Settings persist via `fb2k::configStore` under the `foo_jl_spectrum.` prefix (cfg_var does not persist on macOS v2)

## Requirements

- foobar2000 v2.x for macOS
- macOS 12.0 (Monterey) or later

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_spectrum_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_spectrum_mac/README.md)
