//
//  Loudness.cpp
//  foo_jl_levelmeter_mac
//

#include "Loudness.h"
#include <algorithm>
#include <cmath>
#include <limits>

namespace meter {

namespace {
const double kPi = 3.14159265358979323846;
const double kNegInf = -std::numeric_limits<double>::infinity();

// BS.1770: loudness of a channel-weighted mean square.
inline double energyToLufs(double e) {
    return e > 0 ? -0.691 + 10.0 * std::log10(e) : kNegInf;
}
} // namespace

// K-weighting for any sample rate: the BS.1770 analogue prototypes through
// the bilinear transform. At 48 kHz this reproduces the published
// coefficients.
void kWeightingFilters(double sampleRate, Biquad &shelf, Biquad &highPass) {
    {
        const double f0 = 1681.974450955533;
        const double G = 3.999843853973347;
        const double Q = 0.7071752369554196;
        const double K = std::tan(kPi * f0 / sampleRate);
        const double Vh = std::pow(10.0, G / 20.0);
        const double Vb = std::pow(Vh, 0.4996667741545416);
        const double a0 = 1.0 + K / Q + K * K;
        shelf.b0 = (Vh + Vb * K / Q + K * K) / a0;
        shelf.b1 = 2.0 * (K * K - Vh) / a0;
        shelf.b2 = (Vh - Vb * K / Q + K * K) / a0;
        shelf.a1 = 2.0 * (K * K - 1.0) / a0;
        shelf.a2 = (1.0 - K / Q + K * K) / a0;
    }
    {
        const double f0 = 38.13547087602444;
        const double Q = 0.5003270373238773;
        const double K = std::tan(kPi * f0 / sampleRate);
        const double a0 = 1.0 + K / Q + K * K;
        highPass.b0 = 1.0;
        highPass.b1 = -2.0;
        highPass.b2 = 1.0;
        highPass.a1 = 2.0 * (K * K - 1.0) / a0;
        highPass.a2 = (1.0 - K / Q + K * K) / a0;
    }
    shelf.clear();
    highPass.clear();
}

#pragma mark - LoudnessHistogram

LoudnessHistogram::LoudnessHistogram() {
    const size_t bins = (size_t)std::lround((kMaxLufs - kMinLufs) / kStep);
    _count.assign(bins, 0);
    _energy.assign(bins, 0.0);
}

void LoudnessHistogram::clear() {
    std::fill(_count.begin(), _count.end(), 0u);
    std::fill(_energy.begin(), _energy.end(), 0.0);
    _total = 0;
}

int LoudnessHistogram::binOf(double lufs) const {
    const int b = (int)std::floor((lufs - kMinLufs) / kStep);
    return std::max(0, std::min((int)_count.size() - 1, b));
}

void LoudnessHistogram::add(double energy) {
    const double lufs = energyToLufs(energy);
    if (!(lufs > kMinLufs)) return;
    const int b = binOf(lufs);
    _count[b] += 1;
    _energy[b] += energy;
    ++_total;
}

double LoudnessHistogram::gatedThreshold(double relativeGate) const {
    double e = 0.0;
    for (size_t i = 0; i < _count.size(); ++i) e += _energy[i];
    return energyToLufs(e / (double)_total) + relativeGate;
}

double LoudnessHistogram::gatedLoudness(double relativeGate) const {
    if (_total == 0) return kNegInf;
    const double threshold = gatedThreshold(relativeGate);
    double e = 0.0;
    size_t n = 0;
    for (size_t i = 0; i < _count.size(); ++i) {
        if (_count[i] == 0) continue;
        const double centre = kMinLufs + ((double)i + 0.5) * kStep;
        if (centre < threshold) continue;
        e += _energy[i];
        n += _count[i];
    }
    return n ? energyToLufs(e / (double)n) : kNegInf;
}

double LoudnessHistogram::range() const {
    if (_total == 0) return 0.0;
    const double threshold = gatedThreshold(-20.0);
    auto centreOf = [](size_t i) { return kMinLufs + ((double)i + 0.5) * kStep; };
    size_t n = 0;
    for (size_t i = 0; i < _count.size(); ++i) {
        if (centreOf(i) >= threshold) n += _count[i];
    }
    if (n < 2) return 0.0;

    // Values at the 10th and 95th percentile of what passed the gate.
    const double lowRank = 0.10 * (double)(n - 1);
    const double highRank = 0.95 * (double)(n - 1);
    double low = 0.0, high = 0.0;
    bool haveLow = false;
    size_t seen = 0;
    for (size_t i = 0; i < _count.size(); ++i) {
        if (_count[i] == 0) continue;
        const double centre = centreOf(i);
        if (centre < threshold) continue;
        seen += _count[i];
        if (!haveLow && (double)seen > lowRank) { low = centre; haveLow = true; }
        if ((double)seen > highRank) { high = centre; break; }
    }
    return std::max(0.0, high - low);
}

#pragma mark - LoudnessMeter

LoudnessMeter::LoudnessMeter() : _integrated(kNegInf) {
    std::fill(std::begin(_ringSum), std::end(_ringSum), 0.0);
    std::fill(std::begin(_ringLen), std::end(_ringLen), 0u);
}

void LoudnessMeter::configure(double sampleRate, int channels) {
    channels = channels == 1 ? 1 : 2;
    if (sampleRate == _sampleRate && channels == _channels) return;
    _sampleRate = sampleRate;
    _channels = channels;
    for (int c = 0; c < 2; ++c) kWeightingFilters(sampleRate, _shelf[c], _highPass[c]);
    _subBlockLength = (size_t)std::max(1L, std::lround(sampleRate / 100.0));
    _subBlockFill = 0;
    _subBlockSum = 0.0;
}

void LoudnessMeter::reset() {
    for (int c = 0; c < 2; ++c) { _shelf[c].clear(); _highPass[c].clear(); }
    std::fill(std::begin(_ringSum), std::end(_ringSum), 0.0);
    std::fill(std::begin(_ringLen), std::end(_ringLen), 0u);
    _ringPos = 0;
    _ringFilled = 0;
    _contiguous = 0;
    _sinceStep = 0;
    _subBlockFill = 0;
    _subBlockSum = 0.0;
    _silenceCarry = 0.0;
    _gating.clear();
    _shortTermValues.clear();
    _integrated = kNegInf;
    _range = 0.0;
    _measuredSamples = 0;
}

void LoudnessMeter::process(const float *lr, size_t frames) {
    if (_sampleRate <= 0) return;
    for (size_t i = 0; i < frames; ++i) {
        double sum = 0.0;
        for (int c = 0; c < _channels; ++c) {
            const double y = _highPass[c].process(_shelf[c].process((double)lr[2 * i + c]));
            sum += y * y;   // BS.1770 weight 1.0 for left and right
        }
        _subBlockSum += sum;
        if (++_subBlockFill >= _subBlockLength) closeSubBlock();
    }
    _measuredSamples += frames;
}

void LoudnessMeter::closeSubBlock() {
    _ringSum[_ringPos] = _subBlockSum;
    _ringLen[_ringPos] = (uint32_t)_subBlockFill;
    _ringPos = (_ringPos + 1) % kSubBlocksShortTerm;
    if (_ringFilled < kSubBlocksShortTerm) ++_ringFilled;
    _subBlockSum = 0.0;
    _subBlockFill = 0;
    ++_contiguous;

    if (++_sinceStep < kSubBlocksPerStep) return;
    _sinceStep = 0;
    if (_contiguous >= kSubBlocksMomentary) {
        _gating.add(windowEnergy(kSubBlocksMomentary));
        _integrated = _gating.gatedLoudness(-10.0);
    }
    if (_contiguous >= kSubBlocksShortTerm) {
        _shortTermValues.add(windowEnergy(kSubBlocksShortTerm));
        _range = _shortTermValues.range();
    }
}

void LoudnessMeter::pushSilence(double seconds) {
    if (seconds <= 0) return;
    // A partly filled sub-block is dropped: it would mix audio and silence.
    _subBlockFill = 0;
    _subBlockSum = 0.0;
    _silenceCarry += seconds * 100.0;
    int n = (int)std::floor(_silenceCarry);
    _silenceCarry -= n;
    n = std::min(n, kSubBlocksShortTerm);
    for (int i = 0; i < n; ++i) {
        _ringSum[_ringPos] = 0.0;
        _ringLen[_ringPos] = (uint32_t)_subBlockLength;
        _ringPos = (_ringPos + 1) % kSubBlocksShortTerm;
        if (_ringFilled < kSubBlocksShortTerm) ++_ringFilled;
    }
    if (n > 0) {
        _contiguous = 0;
        _sinceStep = 0;
    }
}

// Mean square (channel-summed) over the last `subBlocks`. Sub-blocks not
// yet seen count as silence, so readings rise from nothing after a reset.
double LoudnessMeter::windowEnergy(int subBlocks) const {
    double sum = 0.0, len = 0.0;
    const int have = std::min(subBlocks, _ringFilled);
    for (int k = 1; k <= have; ++k) {
        const int i = (_ringPos - k + kSubBlocksShortTerm) % kSubBlocksShortTerm;
        sum += _ringSum[i];
        len += _ringLen[i];
    }
    len += (double)(subBlocks - have) * (double)_subBlockLength;
    return len > 0 ? sum / len : 0.0;
}

double LoudnessMeter::momentary() const {
    return _ringFilled ? energyToLufs(windowEnergy(kSubBlocksMomentary)) : kNegInf;
}

double LoudnessMeter::shortTerm() const {
    return _ringFilled ? energyToLufs(windowEnergy(kSubBlocksShortTerm)) : kNegInf;
}

double LoudnessMeter::integrated() const { return _integrated; }

double LoudnessMeter::range() const { return _range; }

double LoudnessMeter::measuredSeconds() const {
    return _sampleRate > 0 ? (double)_measuredSamples / _sampleRate : 0.0;
}

} // namespace meter
