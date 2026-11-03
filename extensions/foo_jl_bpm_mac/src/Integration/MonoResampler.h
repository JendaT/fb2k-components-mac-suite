//
//  MonoResampler.h
//  foo_jl_bpm_mac
//
//  Mono float samples from the decode's rate to the beat network's 22.05
//  kHz with the response of soxr's high-quality resampler, which the network
//  was trained on (see ResampleLowpass.h). Streaming; output sample 0 lines
//  up with input sample 0.
//    - 22.05 kHz: unchanged (upstream does not resample it either)
//    - 44.1 and 88.2 kHz: ResampleLowpass decimating by 2 or 4, exact
//    - other rates: AVAudioConverter (mastering, high quality), then
//      ResampleLowpass for soxr's top-band roll-off
//

#pragma once

#include <cstddef>
#include <memory>
#include <vector>

namespace bpm {

class MonoResampler {
public:
    explicit MonoResampler(double inputRate);
    ~MonoResampler();
    MonoResampler(const MonoResampler &) = delete;
    MonoResampler &operator=(const MonoResampler &) = delete;

    // False when the converter could not be set up or failed; it then stays failed
    bool ok() const;
    // Appends what the input yields so far to `out`
    void process(const float *samples, size_t count, std::vector<float> &out);
    // After the last input: the rest
    void finish(std::vector<float> &out);

private:
    struct Impl;
    std::unique_ptr<Impl> m;
};

} // namespace bpm
