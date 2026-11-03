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
2. **Local analysis** for every local file without a TIDAL answer. The audio is decoded and analysed on this Mac, several tracks at a time at background priority. The tempo is the one of the track's beat grid from the Beat This! network (see [Beat grids](#beat-grids)); a track where the network finds no steady beat anywhere gets "No beat found". Only where the model cannot run does the classic estimator below give the tempo.

`tidal://` entries are shown in the review window, but their tags cannot be written.

## Review window

| Column | Meaning |
|--------|---------|
| Checkbox | Write this row. Checked by default when the new value differs from the tag, except for uncertain results. |
| **Track** | Artist - title; hover for the file path. |
| **Tag** | The current `BPM` tag. |
| **New** | The value that will be written, rounded to a whole number; hover for one decimal. |
| **vs Tag** | `same` (within 1%), `double`, `half` or `different` compared to the current tag. |
| **Source** | TIDAL, Analysis, Analysis (uncertain), or why there is no result. |

- **Double** / **Halve** change the new value of the selected rows, for half/double tempo mistakes.
- Click a column header to sort, e.g. by **vs Tag** to see the disagreements first.
- The summary line counts the sources and, for tracks that already had a tag, how many agree.

Values are written as whole numbers because the ID3 `TBPM` frame and the MP4 `tmpo` atom only hold whole numbers.

## How the local analysis works

The tempo proposed for the tag is the beat grid's: the Beat This! network finds the beats, a straight grid is fitted to the longest steady stretch of them, and its tempo is snapped to a round value within its tolerance (138.000 rather than 137.98). The review window marks it uncertain when the grid is heard on less than 30% of the track.

### Classic estimator (fallback)

1. **Onset strength**: the rise in the log-compressed spectrum from one 5-6 ms step to the next (spectral flux).
2. **Periodicity**: autocorrelation of 8-second stretches of the onset strength, averaged over the whole track.
3. **Choosing the beat level**: a steady beat also repeats at twice its period, so a preference for tempos near 120 BPM picks between the candidates (50-220 BPM).
4. **Precision**: the period is refined from the autocorrelation peaks at one to four times the period.

The method follows librosa's tempo estimator; the code is a new implementation on Apple's Accelerate framework.

### Limitations

- **Half/double tempo**: rare from the network (1 of 46 tagged tracks); the classic estimator's most common mistake, especially around 85 vs 170 BPM (drum and bass is often found at 87). Use Double / Halve.
- **One tempo per track**: tracks with tempo changes and DJ mixes get the tempo of their longest steady stretch (the classic estimator: one averaged value); rubato gets a guess.
- **No clear beat** (ambient, classical, speech): "No beat found" from the network; the classic estimator marks its guess "Analysis (uncertain)" and leaves it unchecked. A grid heard on less than 30% of the track is marked uncertain too.

### Measured so far

47 tagged electronic tracks (psychill, dub techno, psytrance, progressive, drum and bass; full details in the beat grid validation linked below):

| Tempo from | Same as tag | Half | Double | Other |
|------------|-------------|------|--------|-------|
| Beat This! grid (used) | 41 | 0 | 1 | 4, and 1 without a steady beat (No beat found) |
| Classic estimator | 36 | 1 | 1 | 9 |

The classic estimator's misses were 2:3 on drum and bass (116 for 174) and 4:3 on psychill; the network's four are dub techno tracks with a weak pulse. On six tracks without a steady beat (ambient, improvised) the classic estimator invented a tempo (181, 187 BPM); the network finds none.

Earlier, classic estimator only:

80 tracks from the developer's library that already had a BPM tag (mostly psychill and dub techno; where the tags came from is unknown):

| Group | Tracks | Same as tag (within 1%) | Half/double |
|-------|--------|-------------------------|-------------|
| All | 80 | 48% | 11% |
| Clear beat (shown as Analysis) | 45 | 73% | 9% |
| Uncertain | 35 | 14% | 14% |

Where the estimate agrees with the tag, the median difference is 0.15 BPM. The analysis itself takes about 1 ms per track; decoding the file is nearly all of the time.

The tags are not a reliable reference. Traktor-written tags in this library read 0.85% low: for three Saint Cole tracks tagged 128.96, 129.88 and 122.93, the plugin found 129.98, 130.96 and 124.01, and a whole-track phase check found exactly 130.00, 131.00 and 124.00. Some of the "different" results above are the same offset.

## Beat grids

BPM Analyzer also finds each track's beat grid for Waveform Seekbar's phrase markers: one constant grid of beats over the whole track, which beat starts a bar, which bar starts a 32-beat phrase, and per bar how well the music sits on the grid. Grids are stored with the track in foobar2000's database (not in tags) and analysed when the seekbar asks for the playing track, or by **Analyze BPM...** from the same decode.

Beats come from **Beat This!** (Foscarin, Schlüter and Widmer, JKU Linz, ISMIR 2024; MIT license), a beat-tracking network bundled with the component and run on Core ML (about one second per 10-minute track on Apple silicon, on top of decoding):

- **Beats where people tap**: the onset-based tracker this replaces put the grid half a beat off, on the off-beat hi-hat, on 31 of 51 psychill and psytrance tracks; the network finds the kick.
- **Timing from the audio**: each beat the network finds is moved to the onset at it, so the grid is as exact as the attacks (the network's own timing moves by tens of milliseconds with what is playing).
- **Bars from its downbeats**, phrases from where the track's sections change.
- **Beatless passages** (intros, breakdowns, the kick out under a rolling bassline) count as no pulse rather than as the music leaving the grid. A track without a steady beat anywhere gets no grid.

Where the model cannot run, the onset-based tracker takes over. Measured on 84 tracks of the developer's library: [docs/BEATGRID-VALIDATION.md](../extensions/foo_jl_bpm_mac/docs/BEATGRID-VALIDATION.md).
