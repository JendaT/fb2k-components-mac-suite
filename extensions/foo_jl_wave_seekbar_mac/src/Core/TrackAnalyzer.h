//
//  TrackAnalyzer.h
//  foo_wave_seekbar_mac
//
//  One streaming pass over a decoded track: fine-block sample peaks and RMS,
//  100 ms hops of K-weighted power, Lo/Mid/Hi band power and L/R products,
//  clip runs, 4x oversampled true peak, then BS.1770-4 integrated loudness
//  and EBU Tech 3342 loudness range. The drawing data covers the first two
//  channels (front L/R); loudness, true peak and clip runs cover them all.
//  Pure C++ with no foobar2000 SDK or Cocoa dependency, so it is unit-tested
//  standalone.
//

#pragma once

#include "WaveformData.h"
#include <cstddef>
#include <cstdint>
#include <vector>

namespace analysis {

// Crossovers of the Lo / Mid / Hi split: the Vectorscope's tri-band
// defaults (foo_jl_vectorscope_mac, VectorscopeConfig.h), so both
// components band audio the same way. Fixed, because the result is cached.
constexpr double kLowCrossoverHz = 250.0;
constexpr double kHighCrossoverHz = 2000.0;

// Fine blocks: about 1024 frames, larger for long tracks so a track never
// has more than kMaxBlocks of them. Always a divisor or a multiple of the
// hop, so the block and hop grids meet every max(block, hop) frames and
// segments can start on both.
constexpr uint32_t kTargetBlockFrames = 1024;
constexpr size_t kMaxBlocks = 16384;

// Long tracks are analysed in segments decoded in parallel: at least this
// long, at most this many (more segments than cores, so a worker on an
// efficiency core holds the result up less), each decoded from this far
// before its start so the filters settle.
constexpr double kMinSegmentSeconds = 30.0;
constexpr size_t kMaxSegments = 64;
constexpr double kSegmentPrerollSeconds = 1.0;

// |x| at or above this counts as full scale (float sources overshoot 1.0).
constexpr float kClipLevel = 0.9999f;
constexpr int kClipRunLength = 3;

// Second-order IIR section (transposed direct form II), double precision.
struct Biquad {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;

    static Biquad lowpass(double sampleRate, double hz);    // Butterworth, 12 dB/oct
    static Biquad highpass(double sampleRate, double hz);   // Butterworth, 12 dB/oct
    // BS.1770 K-weighting, designed for any sample rate
    static Biquad kShelf(double sampleRate);                // stage 1: +4 dB high shelf
    static Biquad kHighpass(double sampleRate);             // stage 2: RLB high-pass

    inline double process(double x) {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    // Zero state that has decayed to nothing, before it reaches denormals.
    void flush() {
        if (z1 < 1e-15 && z1 > -1e-15) z1 = 0.0;
        if (z2 < 1e-15 && z2 > -1e-15) z2 = 0.0;
    }
};

// Mean square -> loudness (LUFS / LKFS): -0.691 + 10 log10(power).
float loudnessOf(double power);

// BS.1770-4 integrated loudness from 100 ms hops of K-weighted mean square,
// channels summed with their weights: 400 ms blocks at 75 % overlap,
// absolute gate -70 LUFS, relative gate -10 LU. -inf when no block passes
// the gates.
float integratedLoudness(const std::vector<float>& kms, size_t hops);

// EBU Tech 3342 loudness range: 3 s short-term blocks every 100 ms, absolute
// gate -70 LUFS, relative gate -20 LU, 10th to 95th percentile. 0 when
// nothing passes the gates.
float loudnessRange(const std::vector<float>& kms, size_t hops);

uint32_t blockFramesFor(uint64_t expectedFrames, uint32_t sampleRate);
uint32_t hopFramesFor(uint32_t sampleRate);

// A run of frames [start, end); the last segment's end is UINT64_MAX (to
// the end of the track, whatever its real length).
struct Segment {
    uint64_t start;
    uint64_t end;
};

// Splits a track into segments of at least `minSeconds` whose boundaries
// fall on both the block and the hop grid, so segments analysed separately
// join into exactly one sequential pass. One segment when it can't split.
std::vector<Segment> planSegments(uint64_t totalFrames, uint32_t sampleRate,
                                  size_t maxSegments = kMaxSegments, double minSeconds = kMinSegmentSeconds);

class TrackAnalyzer {
public:
    // `channels` drawn, 1 or 2 (the first two of the source; loudness, true
    // peak and clip runs take every source channel).
    // `expectedFrames` sizes the fine blocks; it only needs to be roughly right.
    TrackAnalyzer(uint32_t sampleRate, uint32_t channels, uint64_t expectedFrames);

    // `frames` interleaved frames of `stride` channels each (stride >= 1).
    // `weights` has one BS.1770 weight per source channel for the loudness
    // sum (1 front and centre, 1.41 surround, 0 LFE); null weighs them all 1.
    // A mono chunk in a stereo analysis draws its channel on both lanes but
    // counts once in the loudness.
    void process(const float* samples, size_t frames, uint32_t stride, const float* weights = nullptr);
    void process(const double* samples, size_t frames, uint32_t stride,    // fb2k audio_sample
                 const float* weights = nullptr);

    // Segment mode. setPosition() names the absolute frame of the next
    // sample passed to process() (after a seek). Only frames in
    // [start, end) count; frames before it settle the filters and the
    // true-peak history, and a few frames after it finish clip runs that
    // began inside.
    void setRange(uint64_t start, uint64_t end);
    void setPosition(uint64_t frame) { _frame = frame; }
    uint64_t position() const { return _frame; }

    // Flush the partial block and hop and compute the summary. The duration
    // is that of the counted audio. At the end of the track (no range end)
    // the true-peak interpolator also runs over the last samples. The result
    // is invalid (isValid() false) when no audio was processed.
    WaveformData finish();

    // Joins segment results, in track order, into the whole track's data and
    // recomputes the summary over it.
    static WaveformData merge(std::vector<WaveformData> parts);

private:
    template <typename Sample>
    void processFrames(const Sample* samples, size_t frames, uint32_t stride, const float* weights);
    void flushBlock();
    void flushHop();
    void flushFilters();
    void updateTruePeak(float* history, float x, bool counted);

    WaveformData _data;
    uint32_t _channels;
    uint64_t _frame = 0;                // absolute position of the next frame
    uint64_t _rangeStart = 0;
    uint64_t _rangeEnd = UINT64_MAX;
    uint64_t _counted = 0;              // frames inside the range

    // Current fine block
    uint32_t _blockCount = 0;
    float _blockMin[2] = {}, _blockMax[2] = {};
    double _blockSumSq[2] = {};

    // Current hop
    uint32_t _hopCount = 0;
    double _hopK[2] = {}, _hopKSum = 0.0, _hopMs[2] = {}, _hopLR = 0.0, _hopBand[3] = {};
    bool _lastHopPartial = false;

    // Band filters of the drawn channels: [channel][stage]
    Biquad _low[2][2], _midHp[2][2], _midLp[2][2], _high[2][2];

    // True peak: 48-tap, 4-phase interpolator over the last 12 samples
    static constexpr int kTpPhases = 4;
    static constexpr int kTpTaps = 12;
    float _tpCoeffs[kTpPhases][kTpTaps];
    float _tpGainBound = 1.0f;          // max over phases of sum |h|, a hair over
    float _truePeak = 0.0f;             // linear
    float _samplePeak = 0.0f;           // linear

    // Per source channel, added as chunks bring them
    struct Source {
        Biquad kWeight[2];              // K-weighting stages
        float tpHistory[kTpTaps] = {};
        int clipRun = 0;
    };
    std::vector<Source> _sources;
    Biquad _kShelf, _kHighpass;         // designs the sources start from
    bool _clipActive = false;
};

} // namespace analysis
