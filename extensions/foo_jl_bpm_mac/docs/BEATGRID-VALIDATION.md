# Beat Grid Validation

First library pass of the beat grid (beatgrid spec milestone M5), then the
Beat This! spike and integration (M6, M7), 2026-11-03. Automated parts only:
the listening check of Broken markers and a Mixxx reference are still to do
(see Open).

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

---

# Beat This! (M6 spike, M7 integration)

## Decision: go

Beat This! small0 (JKU Linz, MIT) now gives the beats where its model runs;
the classic tracker is the fallback. Same corpus and harness as above, the
network's logits from the PyTorch reference (Core ML picks the same beats,
see Parity):

| Electronic (69 tracks) | Locked | Drifting | Broken | No pulse | Re-anchor | Tempo vs tags: same / half / double / other | Certain grids |
|---|---|---|---|---|---|---|---|
| Classic (M5, with the refit below) | 71% | 8% | 12% | 4% | 5% | 36 / 1 / 1 / 9 | 50 |
| Beat This! small0 | 62% | 8% | **6%** | 22% | 2% | **41 / 0 / 1 / 4** | 59 |
| Beat This! final0 (78 MB, not shipped) | 62% | 10% | 4% | 22% | 3% | 40 / 1 / 1 / 4 | 61 |

- **The classic grid was half a beat off** on 31 of the 51 tracks where both
  agree on the tempo: it locks onto the off-beat hi-hats of psychill and
  psytrance. At the network's beats the low band (kick) rises 1.52 log units
  on average against 0.66 at the classic ones, the high band 0.92 against
  1.89. Phrase markers hide half a beat at track scale, but beat-synced
  animation and any beat jump or loop would land on the off-beat.
- **Tempo**: 2:3 drum and bass (114.7 for 172, 87 for 174) and 3:4 psychill
  errors are gone; four dub techno tracks with a weak pulse remain "other".
- **Broken halves**, mostly beatless intros and breakdowns that now read No
  pulse (Akshan - Time For Change: 13 Broken to 0). No pulse rises from 4% to
  22%: the network says there is no beat where the classic tracker found
  onsets lined up with the grid by chance.
- **No grid** for six tracks without a steady beat (ambient, improvised,
  soundscape) where the classic tracker invented one (181, 187 BPM...).
- **Locked falls** from 71% to 62%, nearly all of it to No pulse.

## How the network's beats are used

Measured variants (all on the same corpus):

1. Network beats into the classic statistics (onsets at grid beats): Locked
   34% on the first 26 tracks, because the network's beats sit ~10 ms after
   the onsets and the grid followed them.
2. Statistics from the network's own beats: Broken 16-28% (by pulse rule;
   whole corpus and first 26 tracks). Its timing moves by 15-40 ms between
   sections of one track (Akshan: -35 ms for two minutes, then on the grid,
   then +15 ms) while the onsets stay put, so it cannot judge 10 / 25 ms
   thresholds.
3. **Hybrid (shipped)**: the network says which onset is the beat, the onset
   says when. Each network beat moves to the onset peak within 50 ms of it;
   regions, master grid and bar statistics run on those times. A beat counts
   for the statistics only when the network is sure of it (probability at
   least 0.8; in beatless intros its peaks sit at 0.5-0.7, on real beats near
   1) and an onset was found; a bar needs two such beats to have a pulse.
   Bars whose beats fall only on the grid's quarter-, half- or
   three-quarter-beat positions read as no pulse (psytrance breakdowns where
   the kick drops out and the network follows the rolling bassline a 16th
   late). The bar phase comes from the downbeats (majority on the grid), the
   phrase phase from the section changes among starts on that bar phase.

Also found on the way, for both sources: the master grid takes its tempo
from the longest region and its extensions, and on long tracks the snap
tolerance shrinks until 126.026 stays 126.026 (Atmos - Stay Awake drifted 43
ms over four minutes). The master grid is now refitted to every beat within
25 ms of it over the whole track and snapped again.

Confidence threshold 0.6 / 0.8 / 0.95: Broken 8 / 6 / 4%, No pulse 18 / 20 /
27%; 0.8 kept.

## Parity and speed

| Stage | Check | Result |
|---|---|---|
| Core ML conversion (coremltools 9.0, macOS 12 target) | patched PyTorch model vs upstream | identical (difference 0.0) |
| Core ML float32, CPU and GPU | logits and picked beats vs PyTorch, 10 tracks | logits within 1e-4, beats identical on all 10 |
| Core ML float16 (GPU / Neural Engine) | same | logits off by up to 0.3 / 0.9, 1-4% of beats differ: not used |
| Log-mel front end (C++, double) | vs torchaudio in float64 | within 8.5e-5; same beats on 3 tracks |
| Resampling to 22.05 kHz | sure beats vs soxr HQ, 6 tracks | 44.1 kHz decimator 0.43%, 48 kHz (AVAudioConverter + roll-off) 0.17% |

The resampler matters: AVAudioConverter alone keeps energy up to 11.025 kHz
where soxr (what the network was trained on) is down 120 dB, which fills the
top mel band and moved 10-20% of the beats. A FIR with soxr HQ's response
(flat to 10.07 kHz, 181 taps at 22.05 kHz) restores it; for 44.1 and 88.2
kHz the same design at the input rate decimates by 2 or 4 directly.

Time per 10-minute 44.1 kHz track on an M5 Pro, on top of the decode:
resampling 0.08 s, front end 0.16 s, network 0.9 s (21 chunks on CPU and
GPU), grid 2 ms. The first prediction of a session adds about 2 s (Core ML
compiles the model for the GPU). The component grows by 8.8 MB (float32
weights).

## Open

- The listening check of Broken markers (owner), now on Beat This! grids.
- Analyze BPM still proposes the classic tempo estimate; the network's grid
  tempo matched the tags more often (41 vs 36 same, 4 vs 9 other) and could
  replace it there.
- The classic fallback still locks onto off-beats on psychill and psytrance;
  a kick check (low-band rise at the grid beats vs half a beat later) would
  fix most of it if the fallback matters.
- 0.4% of the network's sure beats differ from soxr-resampled input; a full
  soxr-equivalent resampler for other rates would close it.

