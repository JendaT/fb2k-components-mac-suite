//
//  BeatGridAnalyzer.h
//  foo_jl_bpm_mac
//
//  Beat grid and per-bar statistics from the onset envelope, for the
//  seekbar's phrase markers (spec: "Beatgrid & Phrase Markers", Solution A).
//  Plain C++ with no foobar2000 SDK dependency, unit tested standalone.
//
//  Stages (1-2 are OnsetEnvelope and estimateTempo in TempoEstimator.h):
//    3. Beats: dynamic programming over the onset envelope (Ellis 2007, as
//       librosa's beat_track does it, ISC licensed; reimplemented, no code
//       copied), each beat refined to sub-frame precision.
//    4. Constant regions: stretches of beats that fit one straight grid.
//    5. Master grid: the longest stable region extended through compatible
//       ones, the BPM snapped within its tolerance, the phase averaged over
//       the beats near it.
//  Stages 4 and 5 follow the approach of Mixxx's beat utilities as the spec
//  describes it; reimplemented from that description (Mixxx is GPL). One
//  deliberate change: a span's beat length is a least-squares fit over its
//  beats, not the mean between its end beats. Beats carry ~1 ms of detection
//  noise, and an end beat 1 ms off bends an endpoint length enough that a
//  500-beat click track's running error passes the drift limit; the fit
//  can't be bent by its ends, so the first-plus-last-interval check that
//  guarded against that is not needed.
//    6. Bar and phrase phase: which of the 4 beats starts a bar (the offset
//       whose bars change most from one to the next, squared, in log band
//       energy) and which bar starts a phrase (Foote checkerboard novelty
//       over the bars' self-similarity, 8-bar kernel), each with a
//       confidence (best - second) / best.
//  Then per-bar statistics of the raw beats against the master grid, the
//  bars starting on the bar phase (beat 0 when it is unknown).
//

#pragma once

#include "TempoEstimator.h"
#include "../../../../shared/jl_beatgrid_types.h"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace bpm {

// A beat within this of its predicted position matches the grid.
constexpr double kBeatTolerance = 0.025;
// Constant regions: at most kMaxOutliers beats off the span's fitted grid
// by more than the tolerance (never the one after its start), and the
// running sum of signed errors within kDriftLimit.
constexpr double kDriftLimit = 0.100;
constexpr int kMaxOutliers = 1;
// Shorter regions are kept for display but never anchor the master grid.
constexpr uint32_t kMinStableBeats = 16;
// A region with more than this share of beats without pulse (under
// kNoPulseLevel of the median beat) is quiet: neither anchor nor re-anchor.
// Also catches the region the tracker re-syncs in at the end of a silence.
constexpr double kQuietShare = 0.25;
constexpr int kBeatsPerBar = 4;

// Added to frame times so detected beats land on the true onsets: the
// envelope frame reacts while an onset is still in the trailing part of its
// window, so peaks come early. Calibrated on click tracks
// (BeatGridAnalyzerTests: 2.9 ms at 120, 128 and 174 BPM).
constexpr double kOnsetCorrection = 0.0029;

// A stable region whose tempo differs from the previous one's by more than
// this share of a beat starts a new grid (flagged); gradual ramps step less.
constexpr double kTempoStep = 0.01;

struct BeatRegion {
    double startSeconds = 0.0;      // first beat
    double beatSeconds = 0.0;
    uint32_t beatCount = 0;         // intervals; the region ends on beat startSeconds + beatCount * beatSeconds
    bool quiet = false;             // over kQuietShare of its beats have no onset energy (a silence the tracker ran through)
    bool stable() const { return beatCount >= kMinStableBeats && !quiet; }
    double endSeconds() const { return startSeconds + beatCount * beatSeconds; }
};

// One bar (4 beats) of the master grid, as the API carries it
// (jl_beatgrid_types.h). kBarRegionStart: a stable region with another
// phase or tempo than the one before it begins here, its first beat off that
// region's grid (an edit, a re-recorded section) or its tempo stepping by
// more than kTempoStep.
using BarStat = jl_bar_stat;
constexpr uint8_t kBarRegionStart = jl_bar_region_start;
constexpr int kPulseUnit = jl_pulse_unit;

// Tempo references that settle half or double tempo: the estimate times
// 0.5, 1 or 2 within kHintTolerance of one is taken. 0 = none.
struct BeatGridHints {
    double tagBpm = 0.0;
    double tidalBpm = 0.0;          // ISRC-matched only
};
constexpr double kHintTolerance = 0.04;

enum class BeatSource : uint8_t { Classic = 0, BeatThis = 1 };

// What a beat source hands to stages 4-5: the classic tracker, or later a
// network that also predicts downbeats
struct RawBeats {
    std::vector<double> beats;      // seconds, ascending
    std::vector<double> downbeats;  // seconds; empty when the source has none
    BeatSource source = BeatSource::Classic;
};

struct BeatGrid {
    bool valid = false;
    double bpm = 0.0;
    double anchorSeconds = 0.0;     // master-grid beat 0: the first grid beat at or after 0
    float tempoStrength = 0.0f;
    bool uncertain = true;          // tempo strength under kUncertainStrength: draw neutral
    int8_t barPhase = -1;           // beat index mod 4 that starts a bar; -1 unknown (bars from beat 0)
    int8_t phrasePhaseBars = -1;    // bar index mod 8 that starts a 32-beat phrase; -1 unknown
    float barConfidence = 0.0f;
    float phraseConfidence = 0.0f;
    BeatSource source = BeatSource::Classic;
    std::vector<BeatRegion> regions;
    std::vector<BarStat> bars;      // bars[i] covers beats firstBarBeat() + 4i .. + 3, to the end of the track
    std::vector<double> beats;      // the raw beats (diagnostics; not stored)

    double beatSeconds() const { return bpm > 0.0 ? 60.0 / bpm : 0.0; }
    double beatTime(long j) const { return anchorSeconds + static_cast<double>(j) * beatSeconds(); }
    long firstBarBeat() const { return barPhase > 0 ? barPhase : 0; }
};

// The whole pipeline over an envelope from OnsetEnvelope. `bands` are for
// stage 6 (not used yet); `durationSeconds` bounds the bars.
BeatGrid analyseBeatGrid(const std::vector<float> &envelope, const BandEnergies &bands, double framesPerSecond,
                         double firstFrameSeconds, double durationSeconds, const BeatGridHints &hints = {});

// Stages 4-6 and the bar statistics, for beats from any source. The
// envelope gives each bar its pulse; without `bands` the bar and phrase
// phase stay unknown.
BeatGrid buildBeatGrid(const RawBeats &raw, const std::vector<float> &envelope, double framesPerSecond,
                       double firstFrameSeconds, double durationSeconds, const BandEnergies *bands = nullptr);

// How a phrase marker is drawn, from its bars: the shared rule
// (jl_classify_phrase), so the seekbar colours phrases the same way
constexpr double kNoPulseLevel = jl_phrase_no_pulse_level;

namespace detail {

double applyHints(double bpm, const BeatGridHints &hints);
// Stage 3: beat positions in envelope frames (fractional)
std::vector<double> trackBeats(const std::vector<float> &envelope, double framesPerSecond, double bpm);
// Stage 4 over beat times
std::vector<BeatRegion> constantRegions(const std::vector<double> &beats);
bool fitsOneGrid(const std::vector<double> &beats, size_t left, size_t right);
// Stage 5
struct MasterGrid {
    bool valid = false;
    double bpm = 0.0;
    double anchorSeconds = 0.0;
};
MasterGrid masterGrid(const std::vector<BeatRegion> &regions, const std::vector<double> &beats);
double snapBpm(double minBpm, double centerBpm, double maxBpm);
// Stage 6 over the grid's beats
struct Phases {
    int barPhase = -1;              // under jl_phrase_min_confidence: -1
    double barConfidence = 0.0;
    int phraseBars = -1;            // bar (from the bar phase) mod 8 starting a 32-beat phrase
    double phraseConfidence = 0.0;
};
Phases barAndPhrasePhase(const BeatGrid &grid, const BandEnergies &bands, const std::vector<float> &envelope,
                         double framesPerSecond, double firstFrameSeconds, double durationSeconds);

} // namespace detail

} // namespace bpm
