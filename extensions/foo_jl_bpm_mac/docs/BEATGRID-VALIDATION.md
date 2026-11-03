# Beat Grid Validation

First library pass of the beat grid (beatgrid spec milestone M5), 2026-11-03.
Automated part only: the listening check of Broken markers and a Mixxx
reference are still to do (see Open).

## Method

- **Corpus:** 84 FLAC tracks from the owner's library, the first 10 minutes of
  each: psychill 20, dub techno 15, psytrance 10, progressive psytrance 10,
  organic house 8, drum and bass 6, and 15 harder ones (space rock with live
  drums, electroswing, breaks, ambient and improvised music). Picked at a
  fixed stride through each genre folder, not by hand.
- **Run:** decoded with ffmpeg to mono 44.1 kHz and passed through the same
  `OnsetEnvelope` and `analyseBeatGrid` the component uses (an offline
  harness; the code is identical).
- **Phrase states:** 32-beat phrases from the detected phrase phase, each
  classified by `jl_classify_phrase` as the seekbar draws it.
- **Tempo reference:** none trustworthy. Most BPM tags in this library come
  from Traktor (a `TRAKTOR4` field), which an earlier pass found reading
  about 0.85% low, so they are only used to tell same, half and double tempo
  apart (within 4%). Mixxx was not available on this machine.

## Results

| Group | Tracks | With grid | Tempo certain | Phrase phase | Locked | Drifting | Broken | No pulse | Re-anchor |
|---|---|---|---|---|---|---|---|---|---|
| Psychill | 20 | 16 | 10 | 12 | 66% | 10% | 15% | 4% | 6% |
| Dub techno | 15 | 15 | 8 | 13 | 66% | 10% | 10% | 4% | 10% |
| Psytrance | 10 | 10 | 9 | 8 | 74% | 9% | 8% | 6% | 3% |
| Progressive | 10 | 10 | 10 | 10 | 70% | 13% | 10% | 4% | 3% |
| Organic house | 8 | 8 | 8 | 8 | 79% | 4% | 12% | 3% | 2% |
| Drum and bass | 6 | 6 | 5 | 4 | 74% | 8% | 10% | 8% | 0% |
| Harder | 15 | 13 | 7 | 11 | 50% | 20% | 18% | 5% | 7% |
| **All electronic** | 69 | 65 | 50 | 55 | **70%** | 10% | **11%** | 5% | 5% |

Shares are of all phrases of the tracks with a grid. "Tempo certain": tempo
strength at least 0.3. "Phrase phase": a bar and phrase phase claimed at
confidence at least 0.15.

**Tempo against the tags** (electronic tracks with a tag): 36 same, 1 half,
1 double, 9 other. The others are the tempo estimator's known weak spots, not
the grid: 2:3 on two drum and bass tracks (116 for 174), 4:3 on two psychill
tracks, and four dub techno tracks with a tempo strength under 0.25 (no
clear pulse).

**Time** for the beat analysis alone, after decoding (Apple silicon, one
core): 16 ms for a 10-minute track on average, 112 ms for the first hour of a
DJ mix. The decode dominates.

## What changed during this pass

The first in-app test showed phrases "not exactly very precise": on Astral
Projection - Nilaya the bar phase came out unknown and phrases counted from
beat 0. Changes, each checked on the corpus and on synthetic tests:

1. **Phrase and bar phase** from clustered section changes at beat resolution
   (Nilaya: confidence 0.90, markers within 1-3 beats of the changes).
2. **Bar statistics from the audio:** offsets and matches from the onset peak
   nearest each grid beat instead of the tracker's beats. The tracker moves to
   another layer where the kick drops out (a rolling bassline a quarter beat
   off) while the music stays on the grid. Organic house went from 3 to 0
   Broken phrases on the test track, psychill from 4 to 0.
3. **Off-beat bars** (onsets only between the beats, an off-beat bassline
   before the kick) count as no pulse.
4. **Re-anchors** from a phase jump only when the onsets confirm it (Ace
   Ventura - Going Back: 4 false re-anchors to 0).
5. **Region search** doubles and bisects instead of shrinking one beat at a
   time: the hour-long mix went from 2.4 s to 0.11 s, results unchanged.

Tried and dropped: measuring a bar's pulse as the onsets' autocorrelation one
beat apart, to catch busy beatless textures. Broken stayed at 11%, Locked fell
from 70% to 67% (dub techno 66% to 59%: reverb-washed kicks turned into no
pulse).

## What is left

Most remaining Broken phrases on electronic music are beatless intros and
breakdowns: textures of pads, arpeggios and effects with onsets spread evenly
over the beat (Akshan - Time For Change, 0:15-2:25 and 5:53-6:54). The onset
envelope cannot tell such a texture from music that has left the grid; a beat
source that knows where beats are (Beat This!, milestone M6) can.

## Recommendation

- Keep `phrase_markers` off by default for now: about one phrase in nine on
  electronic music is drawn Broken, and most of those are beatless passages
  rather than real breaks.
- Next: the owner's listening check of the Broken markers on about 10 tracks,
  then the Beat This! spike (M6). Its go/no-go criteria from the spec: fewer
  Broken phrases on beatless passages, and the 2:3 / 4:3 tempo errors.

## Open

- Listening check of every Broken marker on 10 tracks (owner).
- A Mixxx 2.5 reference for master BPM and first beat (not installed here).
- Thresholds (10 / 25 ms, 75 / 40% matched) are still the spec's starting
  values: without a reference, tuning them would only fit this corpus.
