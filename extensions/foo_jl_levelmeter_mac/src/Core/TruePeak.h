//
//  TruePeak.h
//  foo_jl_levelmeter_mac
//
//  Inter-sample ("true") peak detection: 4x oversampling with a 48-tap
//  polyphase interpolator, the structure ITU-R BS.1770 describes. Phase 0
//  passes the original samples through, so the result is never below the
//  sample peak. Pure C++, no SDK.
//

#pragma once

#include <cstddef>

namespace meter {

class TruePeakDetector {
public:
    static constexpr int kFactor = 4;
    static constexpr int kTapsPerPhase = 12;
    static constexpr int kTaps = kFactor * kTapsPerPhase;

    TruePeakDetector();
    void reset();

    // Feed `frames` samples read with `stride` (2 for one channel of an
    // interleaved stereo buffer). Returns the largest absolute interpolated
    // value seen in this call.
    float process(const float *x, size_t frames, size_t stride);

    // Filter coefficient table, phase-major: coeff(p, j) multiplies x[n-j]
    // for output phase p. Exposed for tests.
    static float coeff(int phase, int tap);

private:
    float _hist[kTapsPerPhase * 2];   // doubled ring so the taps read contiguously
    int _pos;
};

} // namespace meter
