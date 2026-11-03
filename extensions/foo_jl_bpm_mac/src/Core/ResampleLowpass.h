//
//  ResampleLowpass.h
//  foo_jl_bpm_mac
//
//  The response of soxr's high-quality resampler at 22.05 kHz, for the beat
//  network's input. Beat This! was trained on audio resampled with soxr
//  (HQ): flat to 10.07 kHz (0.913 of the output's Nyquist) and down 120 dB
//  at 11.025 kHz. Other resamplers keep energy up to Nyquist, which fills the
//  highest mel band and moves 10-20% of the network's beats.
//
//  A linear-phase FIR with that response (Kaiser-windowed sinc designed at
//  the input rate, its delay taken out), optionally keeping every Nth output:
//    - factor 1 at 22.05 kHz: the roll-off after another resampler;
//    - factor 2 at 44.1 kHz, 4 at 88.2 kHz: the whole resampling, exact.
//
//  Streams; output sample i lines up with input sample i * factor, and
//  ceil(inputs / factor) come out once finish() is called.
//

#pragma once

#include <cstddef>
#include <vector>

namespace bpm {

class ResampleLowpass {
public:
    explicit ResampleLowpass(int factor = 1);

    void process(const float *samples, size_t count, std::vector<float> &out);
    void finish(std::vector<float> &out);

    int factor() const { return factor_; }
    const std::vector<double> &taps() const { return taps_; }

private:
    void filter(std::vector<float> &out);

    int factor_;
    std::vector<double> taps_;
    std::vector<float> tapsFloat_;
    std::vector<float> history_;    // inputs not yet consumed, zeros before the first
    std::vector<float> scratch_;
    size_t delayToSkip_;            // outputs that are only the filter's delay
    size_t received_ = 0;
    size_t produced_ = 0;
};

} // namespace bpm
