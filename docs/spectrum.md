# Spectrum Analyzer

A real-time spectrum analyzer UI element for foobar2000 macOS. Contributed by [Scannou](https://github.com/Scannou).

## Features

### Real-Time FFT Bars

Frequency bars driven by the core `visualisation_manager` stream at 60 fps. No third-party DSP; the core's normalized FFT (Gauss window) is mapped into a configurable number of bars over a 0 dB to -80 dB display window.

At the low end, where several log-scale bands fall inside a single FFT bin, each band is sampled at its centre frequency (interpolated between neighbouring bins) instead of all reading the same bin as flat steps.

### Draw Modes

| Mode | Description |
|------|-------------|
| **Bars** | Discrete frequency bars with configurable gap and fill style |
| **Curve** | Smooth filled curve spanning the full plot width, with a stroked outline |

The curve uses monotone cubic interpolation (Steffen), so it never overshoots between bands: peaks stay where the data puts them and the curve stays inside the 0..1 range.

![Spectrum Analyzer in curve mode](images/spectrum-overview.png)

### Orientation

Horizontal (frequency along X, magnitude grows up) or vertical (frequency along Y, magnitude grows sideways). The dB scale and frequency axis follow the orientation.

### Three-Layer Dynamics

Each bar has three layers that rise instantly and fall at different rates:

| Layer | Behavior |
|-------|----------|
| **Bar** | Instantaneous level with attack/decay smoothing |
| **Shadow** | Dim fill behind the bar that eases down at a steady medium rate |
| **Peak** | Thin cap that holds for a configurable time, then falls with gentle gravity |

### Bar Styles

| Style | Description |
|-------|-------------|
| **Solid** | Single bar color |
| **Gradient** | Vertical gradient from a darkened to a lightened bar color |
| **Spectrum** | Hue mapped across frequency (low to high) |

### Grid

- **dB scale**: guide lines every 10 dB with labels, positioned against the same 0..-80 dB window the bars use
- **Frequency axis**: logarithmic gridlines at 1..9 x 10^n Hz with de-cluttered labels (20 Hz to 20 kHz)
- Both auto-hide when the view is too small; color and opacity are configurable (0% hides the grid)

### Color Themes

Ten presets stamp bar, background, and grid colors for both light and dark appearance at once: Default (Blue), Classic (Green), Nord, Dracula, Gruvbox, Solarized, Tokyo Night, Catppuccin, Monokai, Sunset. Editing any color well switches the theme selector to Custom.

### Glass Background

Optional translucent behind-window blur instead of a solid background color (same effect as SimPlaylist and Waveform Seekbar).

### Dark Mode Support

Separate bar, background, and grid colors for light and dark appearance; the view redraws on appearance change.

## Configuration

Access settings via **Preferences > Display > Spectrum Analyzer**, or right-click the element and choose **Preferences...**. Changes apply live.

![Spectrum Settings](images/spectrum-settings.png)

### Analysis

| Setting | Description | Range | Default |
|---------|-------------|-------|---------|
| Bars | Number of frequency bars | 16, 24, 32, 48, 64, 96, 128, 192, 256 | 48 |
| FFT size | FFT window length | 1024, 2048, 4096, 8192, 16384 | 4096 |
| Frequency scale | Band mapping | Logarithmic, Linear | Logarithmic |
| Range (Hz) | Lowest and highest displayed frequency | 10-2000 to 1000-24000 | 20 to 20000 |
| Smoothing | Temporal smoothing (higher = smoother) | 0-100 | 60 |

### Dynamics

| Setting | Description | Range | Default |
|---------|-------------|-------|---------|
| Shadow fall | How fast the shadow band falls | 0-100 | 40 |
| Peak fall | How fast the peak line falls after its hold | 0-100 | 30 |
| Peak hold | How long the peak line stays before falling | 0-2000 ms | 400 ms |

### Appearance

| Setting | Description | Default |
|---------|-------------|---------|
| Theme | Color preset (Custom + 10 presets) | Default (Blue) |
| Draw mode | Bars or Curve | Bars |
| Orientation | Horizontal or Vertical | Horizontal |
| Bar style | Solid, Gradient, Spectrum | Gradient |
| Bar gap | Gap between bars, % of slot width | 20% |
| Show peak caps | Falling peak line | On |
| Shadow fill | Slow-decaying dim fill behind bars | On |
| Show dB scale | dB guide lines and labels | On |
| Show frequency axis | Frequency gridlines and labels | On |
| Glass background | Translucent blur instead of solid color | Off |
| Colors (Light / Dark) | Bar and background color per appearance | Blue on gray / lighter blue on near-black |

### Grid

| Setting | Description | Default |
|---------|-------------|---------|
| Opacity | Grid line and label opacity (0% hides) | 40% |
| Color (light / dark) | Grid color per appearance | Neutral gray |

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

- `visualisation_stream_v2::get_spectrum_absolute` with `KStreamFlagNewFFT`, mono channel mode
- Band edges recomputed when the stream's sample rate changes; the DC bin is skipped
- Peak magnitude across each band's bins (reads punchier than the average)
- Per-frame rates for shadow fall, peak gravity, and peak hold are derived from the 0-100 / ms preference values assuming the 60 fps timer

### Rendering

- Core Graphics (Quartz 2D), layer-backed view
- 60 fps `NSTimer` on the main run loop (common modes); redraws only while audio is live or bars are still settling
- Stream released when the view goes off-screen; recreated lazily on the next tick (a fresh stream returns no data for its first reads, so it is not released per idle frame)

### Lifecycle

- An `initquit` service stops every live view's timer and releases its stream before the core tears down the visualisation backend; holding a stream through shutdown throws `exception_service_not_found` and aborts
- Settings persist via `fb2k::configStore` under the `foo_jl_spectrum.` prefix (cfg_var does not persist on macOS v2)

## Requirements

- foobar2000 v2.x for macOS
- macOS 12.0 (Monterey) or later

## Links

- [Main Project](../README.md)
- [Changelog](../extensions/foo_jl_spectrum_mac/CHANGELOG.md)
- [Build Instructions](../extensions/foo_jl_spectrum_mac/README.md)
