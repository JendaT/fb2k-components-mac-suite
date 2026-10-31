//
//  Loudness.h
//  foo_jl_levelmeter_mac
//
//  Programme loudness after ITU-R BS.1770 / EBU R128: K-weighting,
//  momentary (400 ms) and short-term (3 s) loudness, gated integrated
//  loudness and loudness range (EBU Tech 3342). Pure C++, no SDK.
//
//  Audio is cut into 10 ms sub-blocks. The momentary and short-term windows
//  are sums over the last 40 and 300 of them, so the readings update
//  smoothly. Every 100 ms a 400 ms gating block (75% overlap) feeds the
//  integrated measurement and a short-term value feeds the range.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

namespace meter {

struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    double z1 = 0, z2 = 0;

    inline double process(double x) {
        // Transposed direct form II
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void clear() { z1 = z2 = 0; }
};

// The two K-weighting stages (high shelf, then high pass) for a sample rate.
void kWeightingFilters(double sampleRate, Biquad &shelf, Biquad &highPass);

// Histogram of loudness values in 0.01 LU steps, -70..+10 LUFS. Keeps the
// summed energy per bin so gated means stay exact to within one bin.
class LoudnessHistogram {
public:
    static constexpr double kMinLufs = -70.0;
    static constexpr double kMaxLufs = 10.0;
    static constexpr double kStep = 0.01;

    LoudnessHistogram();
    void clear();
    // Adds one value; values at or below the -70 LUFS absolute gate are dropped.
    void add(double energy);
    size_t count() const { return _total; }

    // Gated integrated loudness: absolute gate -70 LUFS, relative gate
    // `relativeGate` LU below the mean of what passes it. -inf when empty.
    double gatedLoudness(double relativeGate) const;

    // Loudness range: the 10th to 95th percentile spread after a -20 LU
    // relative gate. 0 when there is nothing to measure.
    double range() const;

private:
    int binOf(double lufs) const;
    double gatedThreshold(double relativeGate) const;

    std::vector<uint32_t> _count;
    std::vector<double> _energy;
    size_t _total = 0;
};

class LoudnessMeter {
public:
    LoudnessMeter();

    // channels: 1 (mono) or 2. Changing either keeps the integrated
    // measurement; only the filters and sub-block size follow.
    void configure(double sampleRate, int channels);

    // Interleaved stereo frames (two floats each). In mono only the left
    // value of each frame is measured.
    void process(const float *lr, size_t frames);

    // Advance the momentary and short-term windows through `seconds` of
    // silence (playback paused) without feeding the integrated measurement.
    void pushSilence(double seconds);

    // Start a new measurement: integrated, range and both windows.
    void reset();

    // LUFS, or -inf when there is not yet anything to report.
    double momentary() const;
    double shortTerm() const;
    double integrated() const;
    // LU; 0 until there are short-term values to compare.
    double range() const;
    // Seconds of audio in the integrated measurement.
    double measuredSeconds() const;

private:
    void closeSubBlock();
    double windowEnergy(int subBlocks) const;

    static constexpr int kSubBlocksMomentary = 40;   // 400 ms
    static constexpr int kSubBlocksShortTerm = 300;  // 3 s
    static constexpr int kSubBlocksPerStep = 10;     // 100 ms

    double _sampleRate = 0;
    int _channels = 2;
    Biquad _shelf[2], _highPass[2];

    // Current sub-block
    size_t _subBlockLength = 480;
    size_t _subBlockFill = 0;
    double _subBlockSum = 0;

    // Ring of the last 300 sub-blocks: summed weighted square, sample count.
    double _ringSum[kSubBlocksShortTerm];
    uint32_t _ringLen[kSubBlocksShortTerm];
    int _ringPos = 0;
    int _ringFilled = 0;

    // Sub-blocks of real audio since the last gap (pause or reset). Gating
    // blocks and range values are only taken from unbroken audio.
    int _contiguous = 0;
    int _sinceStep = 0;

    // Fractional sub-blocks of silence left over from pushSilence().
    double _silenceCarry = 0;

    LoudnessHistogram _gating;
    LoudnessHistogram _shortTermValues;
    double _integrated;
    double _range = 0;
    size_t _measuredSamples = 0;
};

} // namespace meter
