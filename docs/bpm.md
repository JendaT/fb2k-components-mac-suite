# BPM Analyzer

Finds the tempo of tracks and writes it to the `BPM` tag. Adds a **BPM** submenu to the track context menu, so it works from any playlist view that shows foobar2000's context menu, SimPlaylist included.

## Commands

| Command | What it does |
|---------|--------------|
| **Analyze BPM...** | Finds the tempo of the selected tracks and opens a review window. Nothing is written until you confirm there. |
| **Double BPM** | Multiplies the existing `BPM` tag of the selected tracks by two. |
| **Halve BPM** | Divides the existing `BPM` tag of the selected tracks by two (keeps one decimal, e.g. `62.5`). |

## Where the tempo comes from

1. **TIDAL**, when the Tidal component is installed and signed in: for tracks with an `ISRC` tag and for `tidal://` entries. Only exact matches are used (same ISRC or the TIDAL track itself); tracks are never matched by artist and title, so a cover or a different version cannot lend its tempo to the wrong file.
2. **Local analysis** for every local file without a TIDAL answer. The audio is decoded and analysed on this Mac, several tracks at a time at background priority.

`tidal://` entries are shown in the review window, but their tags cannot be written.

## Review window

| Column | Meaning |
|--------|---------|
| Checkbox | Write this row. Checked by default when the new value differs from the tag. |
| **Track** | Artist - title; hover for the file path. |
| **Tag** | The current `BPM` tag. |
| **New** | The value that will be written, rounded to a whole number; hover for one decimal. |
| **vs Tag** | `same` (within 1%), `double`, `half` or `different` compared to the current tag. |
| **Source** | TIDAL, Analysis, Analysis (no clear beat), or why there is no result. |

- **Double** / **Halve** change the new value of the selected rows, for half/double tempo mistakes.
- Click a column header to sort, e.g. by **vs Tag** to see the disagreements first.
- The summary line counts the sources and, for tracks that already had a tag, how many agree.

Values are written as whole numbers because the ID3 `TBPM` frame and the MP4 `tmpo` atom only hold whole numbers.

## How the local analysis works

1. **Onset strength**: the rise in the log-compressed spectrum from one 5-6 ms step to the next (spectral flux).
2. **Periodicity**: autocorrelation of 8-second stretches of the onset strength, averaged over the whole track.
3. **Choosing the beat level**: a steady beat also repeats at twice its period, so a preference for tempos near 120 BPM picks between the candidates (50-220 BPM).
4. **Precision**: the period is refined from the autocorrelation peaks at one to four times the period.

The method follows librosa's tempo estimator; the code is a new implementation on Apple's Accelerate framework.

### Limitations

- **Half/double tempo**: the most common mistake, especially around 85 vs 170 BPM (drum and bass is often found at 87). Use Double / Halve.
- **One tempo per track**: tracks with tempo changes, DJ mixes and rubato get one averaged value.
- **No clear beat** (ambient, classical, speech): the result is marked "Analysis (no clear beat)" and is a guess.
- Accuracy on real music has not been measured yet. Synthetic test patterns land within 0.1 BPM.
