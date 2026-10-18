//
//  TrackAnalyzer.cpp
//  foo_wave_seekbar_mac
//

#include "TrackAnalyzer.h"
#include <algorithm>
#include <cmath>

namespace analysis {

namespace {
    const double kPi = 3.14159265358979323846;
    const double kButterworthQ = 0.70710678118654752440;

    const float kAbsoluteGate = -70.0f;         // LUFS
    const float kRelativeGateIntegrated = -10.0f;   // LU
    const float kRelativeGateRange = -20.0f;        // LU
    const size_t kMomentaryHops = 4;            // 400 ms
    const size_t kShortTermHops = 30;           // 3 s

    // Keep a crossover inside the range where the design stays stable.
    double clampCorner(double sampleRate, double hz) {
        return std::min(std::max(hz, 10.0), sampleRate * 0.45);
    }

    // Window means of the summed channel powers, `window` hops wide, one per
    // hop position from window-1 to hops-1.
    std::vector<double> windowPowers(const std::vector<float> kms[2], uint32_t channels,
                                     size_t hops, size_t window) {
        std::vector<double> powers;
        if (hops < window) return powers;
        std::vector<double> prefix(hops + 1, 0.0);
        for (size_t i = 0; i < hops; ++i) {
            double z = 0.0;
            for (uint32_t ch = 0; ch < channels; ++ch) z += kms[ch][i];
            prefix[i + 1] = prefix[i] + z;
        }
        powers.reserve(hops - window + 1);
        for (size_t end = window; end <= hops; ++end) {
            powers.push_back((prefix[end] - prefix[end - window]) / window);
        }
        return powers;
    }
}

#pragma mark - Biquad

Biquad Biquad::lowpass(double sampleRate, double hz) {
    const double w0 = 2.0 * kPi * clampCorner(sampleRate, hz) / sampleRate;
    const double cs = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * kButterworthQ);
    const double a0 = 1.0 + alpha;
    Biquad q;
    q.b0 = (1.0 - cs) * 0.5 / a0;
    q.b1 = (1.0 - cs) / a0;
    q.b2 = q.b0;
    q.a1 = -2.0 * cs / a0;
    q.a2 = (1.0 - alpha) / a0;
    return q;
}

Biquad Biquad::highpass(double sampleRate, double hz) {
    const double w0 = 2.0 * kPi * clampCorner(sampleRate, hz) / sampleRate;
    const double cs = std::cos(w0);
    const double alpha = std::sin(w0) / (2.0 * kButterworthQ);
    const double a0 = 1.0 + alpha;
    Biquad q;
    q.b0 = (1.0 + cs) * 0.5 / a0;
    q.b1 = -(1.0 + cs) / a0;
    q.b2 = q.b0;
    q.a1 = -2.0 * cs / a0;
    q.a2 = (1.0 - alpha) / a0;
    return q;
}

// The two BS.1770 stages as analog prototypes, so rates other than 48 kHz
// get the same response (the design libebur128 uses).
Biquad Biquad::kShelf(double sampleRate) {
    const double f0 = 1681.974450955533, gainDb = 3.999843853973347, Q = 0.7071752369554196;
    const double K = std::tan(kPi * f0 / sampleRate);
    const double Vh = std::pow(10.0, gainDb / 20.0);
    const double Vb = std::pow(Vh, 0.4996667741545416);
    const double a0 = 1.0 + K / Q + K * K;
    Biquad q;
    q.b0 = (Vh + Vb * K / Q + K * K) / a0;
    q.b1 = 2.0 * (K * K - Vh) / a0;
    q.b2 = (Vh - Vb * K / Q + K * K) / a0;
    q.a1 = 2.0 * (K * K - 1.0) / a0;
    q.a2 = (1.0 - K / Q + K * K) / a0;
    return q;
}

Biquad Biquad::kHighpass(double sampleRate) {
    const double f0 = 38.13547087602444, Q = 0.5003270373238773;
    const double K = std::tan(kPi * f0 / sampleRate);
    const double a0 = 1.0 + K / Q + K * K;
    Biquad q;
    q.b0 = 1.0;
    q.b1 = -2.0;
    q.b2 = 1.0;
    q.a1 = 2.0 * (K * K - 1.0) / a0;
    q.a2 = (1.0 - K / Q + K * K) / a0;
    return q;
}

#pragma mark - Loudness

float loudnessOf(double power) {
    return power > 0.0 ? (float)(-0.691 + 10.0 * std::log10(power)) : -INFINITY;
}

float integratedLoudness(const std::vector<float> kms[2], uint32_t channels, size_t hops) {
    const std::vector<double> blocks = windowPowers(kms, channels, hops, kMomentaryHops);

    double sum = 0.0;
    size_t count = 0;
    for (double p : blocks) {
        if (loudnessOf(p) > kAbsoluteGate) { sum += p; ++count; }
    }
    if (count == 0) return -INFINITY;

    const float relativeGate = loudnessOf(sum / count) + kRelativeGateIntegrated;
    sum = 0.0;
    count = 0;
    for (double p : blocks) {
        const float l = loudnessOf(p);
        if (l > kAbsoluteGate && l > relativeGate) { sum += p; ++count; }
    }
    return count > 0 ? loudnessOf(sum / count) : -INFINITY;
}

float loudnessRange(const std::vector<float> kms[2], uint32_t channels, size_t hops) {
    const std::vector<double> blocks = windowPowers(kms, channels, hops, kShortTermHops);

    double sum = 0.0;
    size_t count = 0;
    for (double p : blocks) {
        if (loudnessOf(p) > kAbsoluteGate) { sum += p; ++count; }
    }
    if (count == 0) return 0.0f;

    const float relativeGate = loudnessOf(sum / count) + kRelativeGateRange;
    std::vector<float> levels;
    for (double p : blocks) {
        const float l = loudnessOf(p);
        if (l > kAbsoluteGate && l > relativeGate) levels.push_back(l);
    }
    if (levels.empty()) return 0.0f;

    std::sort(levels.begin(), levels.end());
    const size_t n = levels.size();
    const float low = levels[(size_t)std::lround((n - 1) * 0.10)];
    const float high = levels[(size_t)std::lround((n - 1) * 0.95)];
    return high - low;
}

#pragma mark - TrackAnalyzer

TrackAnalyzer::TrackAnalyzer(uint32_t sampleRate, uint32_t channels, uint64_t expectedFrames)
    : _channels(std::clamp(channels, 1u, 2u)) {
    _data.channelCount = _channels;
    _data.sampleRate = std::max(sampleRate, 1u);
    _data.blockFrames = std::max<uint32_t>(kMinBlockFrames,
                                           (uint32_t)((expectedFrames + kMaxBlocks - 1) / kMaxBlocks));
    _data.hopFrames = std::max<uint32_t>(1, (uint32_t)std::lround(_data.sampleRate / 10.0));

    const double fs = _data.sampleRate;
    for (int ch = 0; ch < 2; ++ch) {
        _kWeight[ch][0] = Biquad::kShelf(fs);
        _kWeight[ch][1] = Biquad::kHighpass(fs);
        // Linkwitz-Riley 24 dB/oct: two Butterworth sections per edge
        for (int s = 0; s < 2; ++s) {
            _low[ch][s]   = Biquad::lowpass(fs, kLowCrossoverHz);
            _midHp[ch][s] = Biquad::highpass(fs, kLowCrossoverHz);
            _midLp[ch][s] = Biquad::lowpass(fs, kHighCrossoverHz);
            _high[ch][s]  = Biquad::highpass(fs, kHighCrossoverHz);
        }
    }

    // Hann-windowed sinc, 48 taps, cut off at the original Nyquist; each
    // phase normalised to unity gain at DC.
    const int taps = kTpPhases * kTpTaps;
    const double center = (taps - 1) / 2.0;
    double h[kTpPhases * kTpTaps];
    for (int n = 0; n < taps; ++n) {
        const double t = (n - center) / kTpPhases;
        const double sinc = std::fabs(t) < 1e-12 ? 1.0 : std::sin(kPi * t) / (kPi * t);
        const double window = 0.5 - 0.5 * std::cos(2.0 * kPi * (n + 0.5) / taps);
        h[n] = sinc * window;
    }
    _tpGainBound = 0.0f;
    for (int p = 0; p < kTpPhases; ++p) {
        double sum = 0.0;
        for (int j = 0; j < kTpTaps; ++j) sum += h[kTpPhases * j + p];
        float bound = 0.0f;
        for (int j = 0; j < kTpTaps; ++j) {
            _tpCoeffs[p][j] = (float)(h[kTpPhases * j + p] / sum);
            bound += std::fabs(_tpCoeffs[p][j]);
        }
        _tpGainBound = std::max(_tpGainBound, bound);
    }
}

void TrackAnalyzer::updateTruePeak(int ch, float x) {
    float* hist = _tpHistory[ch];
    std::copy_backward(hist, hist + kTpTaps - 1, hist + kTpTaps);
    hist[0] = x;

    const float a = std::fabs(x);
    if (a > _samplePeak) _samplePeak = a;   // NaN compares false and is ignored
    if (a > _truePeak) _truePeak = a;

    // Skip the interpolation when no phase can exceed the peak so far
    float local = 0.0f;
    for (int j = 0; j < kTpTaps; ++j) local = std::max(local, std::fabs(hist[j]));
    if (local * _tpGainBound <= _truePeak) return;

    for (int p = 0; p < kTpPhases; ++p) {
        float y = 0.0f;
        for (int j = 0; j < kTpTaps; ++j) y += hist[j] * _tpCoeffs[p][j];
        y = std::fabs(y);
        if (y > _truePeak) _truePeak = y;
    }
}

void TrackAnalyzer::process(const float* samples, size_t frames, uint32_t stride) {
    processFrames(samples, frames, stride);
}

void TrackAnalyzer::process(const double* samples, size_t frames, uint32_t stride) {
    processFrames(samples, frames, stride);
}

template <typename Sample>
void TrackAnalyzer::processFrames(const Sample* samples, size_t frames, uint32_t stride) {
    if (!samples || stride == 0) return;

    for (size_t i = 0; i < frames; ++i) {
        const Sample* frame = samples + i * stride;
        float x[2];
        x[0] = (float)frame[0];
        x[1] = (float)(stride > 1 ? frame[1] : frame[0]);

        bool anyClipRun = false;
        for (uint32_t ch = 0; ch < _channels; ++ch) {
            const float s = std::isfinite(x[ch]) ? x[ch] : 0.0f;

            if (_blockCount == 0) {
                _blockMin[ch] = _blockMax[ch] = s;
            } else {
                _blockMin[ch] = std::min(_blockMin[ch], s);
                _blockMax[ch] = std::max(_blockMax[ch], s);
            }
            _blockSumSq[ch] += (double)s * s;
            _hopMs[ch] += (double)s * s;

            const double k = _kWeight[ch][1].process(_kWeight[ch][0].process(s));
            _hopK[ch] += k * k;

            const double lo = _low[ch][1].process(_low[ch][0].process(s));
            const double mid = _midLp[ch][1].process(_midLp[ch][0].process(
                               _midHp[ch][1].process(_midHp[ch][0].process(s))));
            const double hi = _high[ch][1].process(_high[ch][0].process(s));
            _hopBand[0] += lo * lo;
            _hopBand[1] += mid * mid;
            _hopBand[2] += hi * hi;

            updateTruePeak((int)ch, s);

            _clipRun[ch] = std::fabs(s) >= kClipLevel ? _clipRun[ch] + 1 : 0;
            if (_clipRun[ch] >= kClipRunLength) anyClipRun = true;
            x[ch] = s;
        }
        if (_channels == 2) _hopLR += (double)x[0] * x[1];

        if (anyClipRun && !_clipActive) {
            _data.clipRunFrames.push_back(_frame + 1 - kClipRunLength);
        }
        _clipActive = anyClipRun;

        ++_frame;
        if (++_blockCount >= _data.blockFrames) flushBlock();
        if (++_hopCount >= _data.hopFrames) flushHop();
    }

    for (uint32_t ch = 0; ch < _channels; ++ch) {
        for (int s = 0; s < 2; ++s) {
            _kWeight[ch][s].flush();
            _low[ch][s].flush(); _midHp[ch][s].flush(); _midLp[ch][s].flush(); _high[ch][s].flush();
        }
    }
}

void TrackAnalyzer::flushBlock() {
    if (_blockCount == 0) return;
    for (uint32_t ch = 0; ch < _channels; ++ch) {
        _data.blockMin[ch].push_back(std::min(0.0f, _blockMin[ch]));
        _data.blockMax[ch].push_back(std::max(0.0f, _blockMax[ch]));
        _data.blockRms[ch].push_back((float)std::sqrt(_blockSumSq[ch] / _blockCount));
        _blockSumSq[ch] = 0.0;
    }
    _blockCount = 0;
}

void TrackAnalyzer::flushHop() {
    if (_hopCount == 0) return;
    const double n = _hopCount;
    for (uint32_t ch = 0; ch < _channels; ++ch) {
        _data.hopKms[ch].push_back((float)(_hopK[ch] / n));
        _data.hopMs[ch].push_back((float)(_hopMs[ch] / n));
        _hopK[ch] = _hopMs[ch] = 0.0;
    }
    if (_channels == 2) _data.hopLR.push_back((float)(_hopLR / n));
    for (int b = 0; b < 3; ++b) {
        _data.hopBand[b].push_back((float)(_hopBand[b] / n));
        _hopBand[b] = 0.0;
    }
    _lastHopPartial = _hopCount < _data.hopFrames;
    _hopLR = 0.0;
    _hopCount = 0;
}

WaveformData TrackAnalyzer::finish() {
    flushBlock();
    flushHop();

    _data.duration = (double)_frame / _data.sampleRate;

    // A short last hop would skew the gated blocks it falls into
    const size_t gatedHops = _data.hopCount() - (_lastHopPartial ? 1 : 0);
    LoudnessSummary& s = _data.summary;
    s.integrated = integratedLoudness(_data.hopKms, _channels, gatedHops);
    s.range = loudnessRange(_data.hopKms, _channels, gatedHops);
    s.truePeak = _truePeak > 0.0f ? 20.0f * std::log10(_truePeak) : -INFINITY;
    s.samplePeak = _samplePeak > 0.0f ? 20.0f * std::log10(_samplePeak) : -INFINITY;
    s.clipRuns = (uint32_t)_data.clipRunFrames.size();

    return std::move(_data);
}

} // namespace analysis
