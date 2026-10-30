//
//  TrackAnalyzer.cpp
//  foo_wave_seekbar_mac
//

#include "TrackAnalyzer.h"
#include <algorithm>
#include <cmath>
#include <numeric>

namespace waveseek::analysis {

namespace {
    const double kPi = 3.14159265358979323846;
    const double kButterworthQ = 0.70710678118654752440;

    const float kAbsoluteGate = -70.0f;         // LUFS
    const float kRelativeGateIntegrated = -10.0f;   // LU
    const float kRelativeGateRange = -20.0f;        // LU
    const size_t kMomentaryHops = 4;            // 400 ms
    const size_t kShortTermHops = 30;           // 3 s
    const uint64_t kFilterFlushFrames = 1024;   // decayed filter state is zeroed this often

    // Keep a crossover inside the range where the design stays stable.
    double clampCorner(double sampleRate, double hz) {
        return std::min(std::max(hz, 10.0), sampleRate * 0.45);
    }

    // Window means of the summed channel powers, `window` hops wide, one per
    // hop position from window-1 to hops-1.
    std::vector<double> windowPowers(const std::vector<float>& kms, size_t hops, size_t window) {
        std::vector<double> powers;
        if (hops < window) return powers;
        std::vector<double> prefix(hops + 1, 0.0);
        for (size_t i = 0; i < hops; ++i) prefix[i + 1] = prefix[i] + kms[i];
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

float integratedLoudness(const std::vector<float>& kms, size_t hops) {
    const std::vector<double> blocks = windowPowers(kms, hops, kMomentaryHops);

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

float loudnessRange(const std::vector<float>& kms, size_t hops) {
    const std::vector<double> blocks = windowPowers(kms, hops, kShortTermHops);

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

#pragma mark - Segments

uint32_t blockFramesFor(uint64_t expectedFrames, uint32_t sampleRate) {
    const uint64_t hop = hopFramesFor(sampleRate);
    const uint64_t needed = (expectedFrames + kMaxBlocks - 1) / kMaxBlocks;
    // Long tracks: the smallest multiple of the hop that keeps kMaxBlocks
    if (needed > hop) return (uint32_t)std::min<uint64_t>((needed + hop - 1) / hop * hop, UINT32_MAX / hop * hop);

    // Otherwise the divisor of the hop nearest kTargetBlockFrames, by ratio,
    // among those that keep kMaxBlocks
    auto distance = [](uint64_t frames) { return std::fabs(std::log((double)frames / kTargetBlockFrames)); };
    uint64_t best = hop;
    for (uint64_t d = 2; d <= hop && hop / d >= needed; ++d) {
        if (hop % d != 0) continue;
        if (distance(hop / d) < distance(best)) best = hop / d;
        if (hop / d < kTargetBlockFrames) break;   // smaller ones are further off
    }
    return (uint32_t)best;
}

uint32_t hopFramesFor(uint32_t sampleRate) {
    return std::max<uint32_t>(1, (uint32_t)std::lround(std::max(sampleRate, 1u) / 10.0));
}

std::vector<Segment> planSegments(uint64_t totalFrames, uint32_t sampleRate, size_t maxSegments, double minSeconds) {
    const std::vector<Segment> whole = { { 0, UINT64_MAX } };
    if (totalFrames == 0 || sampleRate == 0 || maxSegments < 2) return whole;

    // Boundaries on both grids (the larger of the two, see blockFramesFor)
    const uint64_t unit = std::lcm<uint64_t>(blockFramesFor(totalFrames, sampleRate), hopFramesFor(sampleRate));
    const uint64_t minLength = std::max<uint64_t>((uint64_t)std::ceil(minSeconds * sampleRate),
                                                  (totalFrames + maxSegments - 1) / maxSegments);
    const uint64_t length = (minLength + unit - 1) / unit * unit;
    if (length == 0 || length >= totalFrames) return whole;

    std::vector<Segment> segments;
    for (uint64_t start = 0; start < totalFrames; start += length) {
        segments.push_back({ start, start + length });
    }
    segments.back().end = UINT64_MAX;
    if (segments.size() < 2) return whole;
    return segments;
}

#pragma mark - TrackAnalyzer

TrackAnalyzer::TrackAnalyzer(uint32_t sampleRate, uint32_t channels, uint64_t expectedFrames)
    : _channels(std::clamp(channels, 1u, 2u)) {
    _data.channelCount = _channels;
    _data.sampleRate = std::max(sampleRate, 1u);
    _data.blockFrames = blockFramesFor(expectedFrames, _data.sampleRate);
    _data.hopFrames = hopFramesFor(_data.sampleRate);

    const double fs = _data.sampleRate;
    _kShelf = Biquad::kShelf(fs);
    _kHighpass = Biquad::kHighpass(fs);
    for (int ch = 0; ch < 2; ++ch) {
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
    // Float rounding in a phase's sum stays under this margin, so a skipped
    // interpolation never hides a peak and the result doesn't depend on
    // where a segment starts
    _tpGainBound *= 1.0001f;
}

void TrackAnalyzer::setRange(uint64_t start, uint64_t end) {
    _rangeStart = start;
    _rangeEnd = std::max(start, end);
}

void TrackAnalyzer::updateTruePeak(float* hist, float x, bool counted) {
    std::copy_backward(hist, hist + kTpTaps - 1, hist + kTpTaps);
    hist[0] = x;
    if (!counted) return;

    const float a = std::fabs(x);
    if (a > _samplePeak) _samplePeak = a;   // NaN compares false and is ignored
    // Kept local: a store to the member might alias the history
    float peak = _truePeak;
    if (a > peak) peak = a;

    // Skip the interpolation when no phase can exceed the peak so far
    float local = 0.0f;
    for (int j = 0; j < kTpTaps; ++j) local = std::max(local, std::fabs(hist[j]));
    if (local * _tpGainBound > peak) {
        for (int p = 0; p < kTpPhases; ++p) {
            float y = 0.0f;
            for (int j = 0; j < kTpTaps; ++j) y += hist[j] * _tpCoeffs[p][j];
            y = std::fabs(y);
            if (y > peak) peak = y;
        }
    }
    _truePeak = peak;
}

void TrackAnalyzer::process(const float* samples, size_t frames, uint32_t stride, const float* weights) {
    processFrames(samples, frames, stride, weights);
}

void TrackAnalyzer::process(const double* samples, size_t frames, uint32_t stride, const float* weights) {
    processFrames(samples, frames, stride, weights);
}

template <typename Sample>
void TrackAnalyzer::processFrames(const Sample* samples, size_t frames, uint32_t stride, const float* weights) {
    if (!samples || stride == 0) return;
    // A channel first seen here starts at rest, as at the start of the track
    while (_sources.size() < stride) {
        Source source;
        source.kWeight[0] = _kShelf;
        source.kWeight[1] = _kHighpass;
        _sources.push_back(source);
    }

    for (size_t i = 0; i < frames; ++i) {
        const Sample* frame = samples + i * stride;

        // Outside the range the filters, true-peak history and clip runs
        // still run, so a segment starts and ends as a sequential pass would
        const bool counted = _frame >= _rangeStart && _frame < _rangeEnd;

        // Every source channel: weighted K power, true peak and clip runs.
        // The first two are also drawn; a mono chunk draws on both lanes.
        float x[2] = {};
        double k[2] = {};
        double kSum = 0.0;
        bool anyClipRun = false;
        for (uint32_t c = 0; c < stride; ++c) {
            Source& source = _sources[c];
            const float v = (float)frame[c];
            const float s = std::isfinite(v) ? v : 0.0f;
            const float weight = weights ? weights[c] : 1.0f;
            if (c < 2 || weight > 0.0f) {
                const double kc = source.kWeight[1].process(source.kWeight[0].process(s));
                kSum += weight * kc * kc;
                if (c < 2) { x[c] = s; k[c] = kc; }
            }
            updateTruePeak(source.tpHistory, s, counted);
            source.clipRun = std::fabs(s) >= kClipLevel ? source.clipRun + 1 : 0;
            if (source.clipRun >= kClipRunLength) anyClipRun = true;
        }
        if (stride == 1) { x[1] = x[0]; k[1] = k[0]; }

        for (uint32_t ch = 0; ch < _channels; ++ch) {
            const float s = x[ch];
            const double lo = _low[ch][1].process(_low[ch][0].process(s));
            const double mid = _midLp[ch][1].process(_midLp[ch][0].process(
                               _midHp[ch][1].process(_midHp[ch][0].process(s))));
            const double hi = _high[ch][1].process(_high[ch][0].process(s));

            if (counted) {
                if (_blockCount == 0) {
                    _blockMin[ch] = _blockMax[ch] = s;
                } else {
                    _blockMin[ch] = std::min(_blockMin[ch], s);
                    _blockMax[ch] = std::max(_blockMax[ch], s);
                }
                _blockSumSq[ch] += (double)s * s;
                _hopMs[ch] += (double)s * s;
                _hopK[ch] += k[ch] * k[ch];
                _hopBand[0] += lo * lo;
                _hopBand[1] += mid * mid;
                _hopBand[2] += hi * hi;
            }
        }

        // A run belongs to the segment it starts in
        if (anyClipRun && !_clipActive) {
            const uint64_t runStart = _frame + 1 - kClipRunLength;
            if (runStart >= _rangeStart && runStart < _rangeEnd) _data.clipRunFrames.push_back(runStart);
        }
        _clipActive = anyClipRun;
        ++_frame;
        // On the frame grid rather than per call, so how the decoder chunks
        // the audio can't change the result (segments join exactly)
        if (_frame % kFilterFlushFrames == 0) flushFilters();

        if (!counted) continue;
        _hopKSum += kSum;
        if (_channels == 2) _hopLR += (double)x[0] * x[1];
        ++_counted;
        if (++_blockCount >= _data.blockFrames) flushBlock();
        if (++_hopCount >= _data.hopFrames) flushHop();
    }
}

void TrackAnalyzer::flushFilters() {
    for (Source& source : _sources) {
        source.kWeight[0].flush();
        source.kWeight[1].flush();
    }
    for (uint32_t ch = 0; ch < _channels; ++ch) {
        for (int s = 0; s < 2; ++s) {
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
    _data.hopKmsSum.push_back((float)(_hopKSum / n));
    if (_channels == 2) _data.hopLR.push_back((float)(_hopLR / n));
    for (int b = 0; b < 3; ++b) {
        _data.hopBand[b].push_back((float)(_hopBand[b] / n));
        _hopBand[b] = 0.0;
    }
    _lastHopPartial = _hopCount < _data.hopFrames;
    _hopKSum = 0.0;
    _hopLR = 0.0;
    _hopCount = 0;
}

WaveformData TrackAnalyzer::finish() {
    // The interpolator reads about kTpTaps / 2 samples behind the newest one:
    // at the real end of the track, run it over that much silence so the
    // last samples count as they would before a pause
    if (_rangeEnd == UINT64_MAX && _counted > 0) {
        for (Source& source : _sources) {
            for (int i = 0; i < kTpTaps / 2; ++i) updateTruePeak(source.tpHistory, 0.0f, true);
        }
    }
    flushBlock();
    flushHop();

    _data.duration = (double)_counted / _data.sampleRate;

    // A short last hop would skew the gated blocks it falls into
    const size_t gatedHops = _data.hopCount() - (_lastHopPartial ? 1 : 0);
    LoudnessSummary& s = _data.summary;
    s.integrated = integratedLoudness(_data.hopKmsSum, gatedHops);
    s.range = loudnessRange(_data.hopKmsSum, gatedHops);
    s.truePeak = _truePeak > 0.0f ? 20.0f * std::log10(_truePeak) : -INFINITY;
    s.samplePeak = _samplePeak > 0.0f ? 20.0f * std::log10(_samplePeak) : -INFINITY;
    s.clipRuns = (uint32_t)_data.clipRunFrames.size();

    return std::move(_data);
}

WaveformData TrackAnalyzer::merge(std::vector<WaveformData> parts) {
    if (parts.empty()) return WaveformData();
    if (parts.size() == 1) return std::move(parts[0]);

    WaveformData out;
    out.channelCount = parts[0].channelCount;
    out.sampleRate = parts[0].sampleRate;
    out.blockFrames = parts[0].blockFrames;
    out.hopFrames = parts[0].hopFrames;

    auto append = [](std::vector<float>& to, const std::vector<float>& from) {
        to.insert(to.end(), from.begin(), from.end());
    };
    uint64_t frames = 0;
    float truePeak = -INFINITY, samplePeak = -INFINITY;
    for (const WaveformData& p : parts) {
        for (uint32_t ch = 0; ch < out.channelCount; ++ch) {
            append(out.blockMin[ch], p.blockMin[ch]);
            append(out.blockMax[ch], p.blockMax[ch]);
            append(out.blockRms[ch], p.blockRms[ch]);
            append(out.hopKms[ch], p.hopKms[ch]);
            append(out.hopMs[ch], p.hopMs[ch]);
        }
        append(out.hopKmsSum, p.hopKmsSum);
        append(out.hopLR, p.hopLR);
        for (int b = 0; b < 3; ++b) append(out.hopBand[b], p.hopBand[b]);
        out.clipRunFrames.insert(out.clipRunFrames.end(), p.clipRunFrames.begin(), p.clipRunFrames.end());
        frames += (uint64_t)std::llround(p.duration * p.sampleRate);
        truePeak = std::max(truePeak, p.summary.truePeak);
        samplePeak = std::max(samplePeak, p.summary.samplePeak);
    }
    out.duration = (double)frames / out.sampleRate;

    // As finish(): a short last hop stays out of the gates
    const size_t gatedHops = out.hopCount() - (frames % out.hopFrames != 0 ? 1 : 0);
    LoudnessSummary& s = out.summary;
    s.integrated = integratedLoudness(out.hopKmsSum, gatedHops);
    s.range = loudnessRange(out.hopKmsSum, gatedHops);
    s.truePeak = truePeak;
    s.samplePeak = samplePeak;
    s.clipRuns = (uint32_t)out.clipRunFrames.size();
    return out;
}

} // namespace waveseek::analysis
