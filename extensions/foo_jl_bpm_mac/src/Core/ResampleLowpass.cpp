//
//  ResampleLowpass.cpp
//  foo_jl_bpm_mac
//

#include "ResampleLowpass.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>

namespace bpm {

namespace {

constexpr double kOutputRate = 22050.0;
constexpr double kPassHz = 0.913 * kOutputRate / 2.0;   // soxr HQ passband end
constexpr double kStopHz = kOutputRate / 2.0;
constexpr double kAttenuationDb = 120.0;                // soxr HQ: 20-bit precision

// Modified Bessel function of the first kind, order 0 (Kaiser window)
double besselI0(double x) {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 200; k++) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

} // namespace

ResampleLowpass::ResampleLowpass(int factor) : factor_(std::max(1, factor)) {
    // Kaiser's design formulas at the input rate: beta for the attenuation,
    // length for the transition width, cutoff halfway through it
    const double rate = kOutputRate * factor_;
    const double beta = 0.1102 * (kAttenuationDb - 8.7);
    const double transition = 2.0 * M_PI * (kStopHz - kPassHz) / rate;
    size_t n = static_cast<size_t>(std::ceil((kAttenuationDb - 8.0) / (2.285 * transition)));
    // Odd, with a delay of a whole number of outputs
    const size_t step = 2 * static_cast<size_t>(factor_);
    n = ((n - 1 + step - 1) / step) * step + 1;
    const double cutoff = (kPassHz + kStopHz) / 2.0 / rate;
    taps_.resize(n);
    double sum = 0.0;
    const double half = static_cast<double>(n - 1) / 2.0, norm = besselI0(beta);
    for (size_t i = 0; i < n; i++) {
        const double k = static_cast<double>(i) - half;
        const double sinc = k == 0.0 ? 1.0 : std::sin(2.0 * M_PI * cutoff * k) / (2.0 * M_PI * cutoff * k);
        const double r = k / half;
        const double window = besselI0(beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / norm;
        taps_[i] = 2.0 * cutoff * sinc * window;
        sum += taps_[i];
    }
    for (double &t : taps_) t /= sum;   // unity gain at DC
    tapsFloat_.assign(taps_.begin(), taps_.end());
    // Zeros before the first sample, then the delay comes off the front
    history_.assign(n - 1, 0.0f);
    delayToSkip_ = (n - 1) / 2 / static_cast<size_t>(factor_);
}

// Every output whose window is complete; symmetric taps make vDSP's
// correlation the convolution
void ResampleLowpass::filter(std::vector<float> &out) {
    const size_t n = tapsFloat_.size(), f = static_cast<size_t>(factor_);
    if (history_.size() < n) return;
    const size_t m = (history_.size() - n) / f + 1;
    scratch_.resize(m);
    vDSP_desamp(history_.data(), static_cast<vDSP_Stride>(f), tapsFloat_.data(), scratch_.data(), m, n);
    const size_t skip = std::min(delayToSkip_, m);
    delayToSkip_ -= skip;
    const size_t owed = (received_ + f - 1) / f - produced_;
    const size_t give = std::min(m - skip, owed);
    out.insert(out.end(), scratch_.begin() + static_cast<std::ptrdiff_t>(skip),
               scratch_.begin() + static_cast<std::ptrdiff_t>(skip + give));
    produced_ += give;
    history_.erase(history_.begin(), history_.begin() + static_cast<std::ptrdiff_t>(m * f));
}

void ResampleLowpass::process(const float *samples, size_t count, std::vector<float> &out) {
    history_.insert(history_.end(), samples, samples + count);
    received_ += count;
    filter(out);
}

void ResampleLowpass::finish(std::vector<float> &out) {
    // Zeros after the last sample flush what the delay holds back
    history_.insert(history_.end(), tapsFloat_.size() + static_cast<size_t>(factor_), 0.0f);
    filter(out);
}

} // namespace bpm
