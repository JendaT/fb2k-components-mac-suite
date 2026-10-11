# Spectrogram

A scrolling spectrogram UI element for foobar2000 macOS: frequency on the vertical axis, time on the horizontal axis, level as color. Contributed by [Scannou](https://github.com/Scannou).

## Features

### Scrolling Display

New audio enters at the right edge and moves left at a fixed speed. Columns sit on a fixed time grid derived from the playback position (one per device pixel of travel), so the picture is the same whatever the frame timing. Pausing or stopping playback holds the picture; seeking carries on from the new position.

### Multi-Resolution Analysis

One FFT size cannot be sharp in both pitch and time. With **Multi-resolution** on, each column runs three FFTs centred on the same instant and each frequency region reads the one that suits it:

| Region | Window (at 44.1/48 kHz, FFT size 4096) | Effect |
|--------|------------------------------------------|--------|
| Below 200 Hz | 4x (16384 samples) | Bass notes resolve as thin lines |
| 400 Hz to 2 kHz | 1x (4096 samples) | Balanced |
| Above 4 kHz | 1/4 (1024 samples) | Hi-hats and transients stay narrow in time |

The octaves in between (200-400 Hz, 2-4 kHz) blend the two neighbours in dB. Windows are doubled at 88.2/96 kHz and quadrupled above, so resolution stays the same across sample rates.

Levels are calibrated in dBFS: a full-scale sine reads 0 dB.

### Frequency Scales

| Scale | Description |
|-------|-------------|
| **Logarithmic** | Equal height per octave |
| **Mel** | Between logarithmic and linear; more room for mids and highs |
| **Linear** | Equal height per Hz |

### Colormaps

Inferno, Magma, Classic (black, blue, purple, red, yellow, white), Ice, Heat, Plasma, Viridis, Turbo, Grayscale. The panel background takes the colormap's floor color.

### Axis and Scale

- **Frequency axis**: labels on the left edge, de-cluttered to fit the height (round numbers first)
- **Grid lines**: lines across the plot at the labelled frequencies, with adjustable opacity
- **dB color scale**: color bar on the right edge with the level each color stands for
- The axis and the scale auto-hide when the panel is too small

### Frequency Readout

Click and hold the left mouse button to show a marker with the frequency and nearest note (A4 = 440 Hz) under the cursor; drag to scrub.

### Context Menu

Right-click the element:

| Item | Description |
|------|-------------|
| **Freeze** | Stop scrolling while playback continues |
| **Clear** | Drop the picture drawn so far |
| **Preferences...** | Open the settings page |

## Configuration

Access settings via **Preferences > Display > Spectrogram**, or right-click the element and choose **Preferences...**. Changes apply live.

### Analysis

| Setting | Description | Range | Default |
|---------|-------------|-------|---------|
| FFT size | Base window length at 44.1/48 kHz | 1024, 2048, 4096, 8192, 16384 | 4096 |
| Multi-resolution | 4x window for bass, 1/4 window for treble | On/Off | On |
| Window | Hann, or Blackman-Harris (cleaner at wide dB ranges, slightly broader lines) | | Hann |
| Channel | Signal analysed | Mid (L + R), Left, Right, Side (L - R) | Mid |
| Frequency scale | Axis mapping | Logarithmic, Mel, Linear | Logarithmic |
| Range (Hz) | Lowest and highest displayed frequency | 10-2000 to 1000-96000 | 20 to 20000 |

Changing the frequency scale or range clears the picture, since older columns would no longer line up with the axis.

### Display

| Setting | Description | Range | Default |
|---------|-------------|-------|---------|
| Colormap | Color ramp | 9 presets | Inferno |
| Top level | Level shown in the brightest color | -40 to 0 dB | 0 dB |
| Range | dB span below the top level | 40 to 140 dB | 90 dB |
| Slope | Tilt around 1 kHz that brightens treble | Off, 1.5, 3, 4.5, 6 dB/octave | Off |
| Scroll speed | Horizontal travel | 30, 60, 120, 240 pt/s | 120 pt/s |
| Show frequency axis | Frequency labels on the left | On/Off | On |
| Show dB color scale | Color bar on the right | On/Off | On |
| Grid lines | Opacity of frequency lines across the plot (0% hides) | 0-100% | 15% |

With a slope set, the dB color scale is exact only at 1 kHz.

## Layout Editor

Add Spectrogram to your layout using any of these names:
- `spectrogram` (recommended)
- `Spectrogram`
- `foo_jl_spectrogram`
- `jl_spectrogram`

Example layout:
```
splitter vertical
  waveform-seekbar
  spectrogram
  simplaylist
```

## Technical Details

### Audio Analysis

- Raw PCM from `visualisation_stream_v2::get_chunk_absolute`, downmixed to the selected channel; FFTs run in the component with Accelerate (vDSP)
- Each column's windows are centred on the column's time, reaching into audio already buffered for output; if that audio is not available the window ends at the column's time instead
- Per row, bins are peak-picked where a row spans several bins and interpolated in dB where bins are wider than rows
- `SpectrogramEngine` and `SpectrogramColormaps` have no SDK or Cocoa dependency and are unit-tested standalone; the tests gate the build

### Rendering

- The picture is a strip of 256-column tile layers. Only the newest tile is re-uploaded each frame; the others are just moved, and dropped once they leave the plot
- 60 fps `NSTimer` on the main run loop (common modes); nothing is drawn while the stream time does not advance
- After a resize the existing tiles stretch to the new height; new columns switch to the new pixel height once the size has held for 0.25 s
- Stream released when the view goes off-screen; recreated lazily on the next tick

### Lifecycle

- An `initquit` service stops every live view's timer and releases its stream before the core tears down the visualisation backend; holding a stream through shutdown throws `exception_service_not_found` and aborts
