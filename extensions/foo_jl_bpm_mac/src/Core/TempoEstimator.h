//
//  TempoEstimator.h
//  foo_jl_bpm_mac
//
//  Tempo (BPM) estimation from decoded audio. Plain C++ on Accelerate, with
//  no foobar2000 SDK dependency, so it is unit tested standalone.
//
//  Method (follows librosa's tempo estimator, ISC licensed; reimplemented,
//  no code copied):
//    1. Onset strength: half-wave rectified spectral flux of the
//       log-compressed magnitude spectrum, 150-300 values per second.
//    2. Tempogram: autocorrelation of 8-second Hann-windowed stretches of
//       the onset strength, each normalised to its zero lag, averaged over
//       the whole track.
//    3. A log-normal prior centred on 120 BPM picks between the periodicity
//       peaks. This is where half/double tempo mistakes come from: a steady
//       beat correlates at 2x its period too, and the prior decides.
//    4. The chosen period is refined to sub-frame precision from the
//       autocorrelation peaks at 1-4 times the period.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace bpm {

// Onset strength built incrementally from decoded audio, so a track of any
// length only ever holds its envelope in memory, never the PCM.
class OnsetEnvelope {
public:
    explicit OnsetEnvelope(double sampleRate);
    ~OnsetEnvelope();
    OnsetEnvelope(const OnsetEnvelope &) = delete;
    OnsetEnvelope &operator=(const OnsetEnvelope &) = delete;

    // Interleaved samples, any channel count; channels are averaged.
    void addInterleaved(const float *samples, size_t frames, unsigned channels);
    void addInterleaved(const double *samples, size_t frames, unsigned channels);

    double framesPerSecond() const;
    double secondsAdded() const;
    const std::vector<float> &values() const;

private:
    struct Impl;
    std::unique_ptr<Impl> m;
};

struct TempoOptions {
    double minBpm = 50.0;
    double maxBpm = 220.0;
    double priorCenterBpm = 120.0;
    double priorWidthOctaves = 1.0;
};

struct TempoResult {
    bool valid = false;
    double bpm = 0.0;
    // Normalised autocorrelation at the beat period, 0..1. Low values mean
    // no clear steady pulse (ambient, rubato, speech), so the BPM is a guess.
    double strength = 0.0;
};

// Below this the result is shown as uncertain. On 80 tagged tracks the
// estimate agreed with the tag 73% of the time at or above 0.3, 19% between
// 0.1 and 0.3, and 7% below 0.1.
constexpr double kUncertainStrength = 0.3;

// Needs at least kMinimumSeconds of envelope; shorter input is not valid.
constexpr double kMinimumSeconds = 6.0;

TempoResult estimateTempo(const std::vector<float> &envelope, double framesPerSecond,
                          const TempoOptions &options = {});

} // namespace bpm
