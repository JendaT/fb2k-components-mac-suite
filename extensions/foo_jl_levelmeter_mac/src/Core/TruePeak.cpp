//
//  TruePeak.cpp
//  foo_jl_levelmeter_mac
//

#include "TruePeak.h"
#include <cmath>
#include <cstring>

namespace meter {

namespace {

const double kPi = 3.14159265358979323846;

// Modified Bessel function of the first kind, order 0 (series form).
double besselI0(double x) {
    double sum = 1.0, term = 1.0;
    const double q = x * x / 4.0;
    for (int k = 1; k < 50; ++k) {
        term *= q / ((double)k * k);
        sum += term;
        if (term < sum * 1e-12) break;
    }
    return sum;
}

struct Table {
    float c[TruePeakDetector::kFactor][TruePeakDetector::kTapsPerPhase];

    Table() {
        // Windowed sinc with its cutoff at the original Nyquist frequency,
        // centred on tap 24 so phase 0 reduces to a pure delay.
        const int L = TruePeakDetector::kFactor;
        const int N = TruePeakDetector::kTaps;
        const double centre = N / 2.0;
        const double beta = 7.0;
        const double i0b = besselI0(beta);
        double h[TruePeakDetector::kTaps];
        for (int k = 0; k < N; ++k) {
            const double t = (k - centre) / L;
            const double sinc = t == 0.0 ? 1.0 : std::sin(kPi * t) / (kPi * t);
            const double r = (k - centre) / centre;
            const double w = besselI0(beta * std::sqrt(std::fmax(0.0, 1.0 - r * r))) / i0b;
            h[k] = sinc * w;
        }
        for (int p = 0; p < L; ++p) {
            // Unity DC gain for every phase, so a constant reads flat.
            double sum = 0.0;
            for (int j = 0; j < TruePeakDetector::kTapsPerPhase; ++j) sum += h[p + L * j];
            for (int j = 0; j < TruePeakDetector::kTapsPerPhase; ++j) {
                c[p][j] = (float)(h[p + L * j] / sum);
            }
        }
    }
};

const Table &table() {
    static const Table t;
    return t;
}

} // namespace

TruePeakDetector::TruePeakDetector() { reset(); }

void TruePeakDetector::reset() {
    std::memset(_hist, 0, sizeof(_hist));
    _pos = 0;
}

float TruePeakDetector::coeff(int phase, int tap) {
    return table().c[phase][tap];
}

float TruePeakDetector::process(const float *x, size_t frames, size_t stride) {
    const Table &t = table();
    float peak = 0.0f;
    for (size_t i = 0; i < frames; ++i) {
        // Newest sample at _hist[_pos], older ones following it.
        _pos = (_pos == 0) ? kTapsPerPhase - 1 : _pos - 1;
        const float v = x[i * stride];
        _hist[_pos] = v;
        _hist[_pos + kTapsPerPhase] = v;
        const float *h = _hist + _pos;
        for (int p = 0; p < kFactor; ++p) {
            float acc = 0.0f;
            for (int j = 0; j < kTapsPerPhase; ++j) acc += t.c[p][j] * h[j];
            const float a = std::fabs(acc);
            if (a > peak) peak = a;
        }
    }
    return peak;
}

} // namespace meter
