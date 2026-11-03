//
//  TempoEstimator.cpp
//  foo_jl_bpm_mac
//

#include "TempoEstimator.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>

namespace bpm {

namespace {

// Envelope rate the hop size aims for. A power-of-two hop lands every common
// sample rate between 150 and 300 frames per second.
constexpr double kTargetFramesPerSecond = 180.0;

// Log compression gain applied before the flux, so quiet passages still
// produce onsets instead of being dominated by the loudest hits.
constexpr float kCompression = 1000.0f;

// Flux ignores bins above this; content up there is mostly noise and
// cymbal wash that blurs the onsets.
constexpr double kMaxFluxHz = 16000.0;

// Tempogram window and the local-mean width subtracted from the envelope.
constexpr double kWindowSeconds = 8.0;
constexpr double kLocalMeanSeconds = 0.5;

// Refinement uses the autocorrelation peaks at up to this many periods.
constexpr int kMaxHarmonic = 4;

size_t hopForRate(double sampleRate) {
    const double ideal = std::max(sampleRate / kTargetFramesPerSecond, 16.0);
    const int exponent = std::clamp(static_cast<int>(std::lround(std::log2(ideal))), 4, 12);
    return static_cast<size_t>(1) << exponent;
}

vDSP_Length log2Of(size_t powerOfTwo) {
    vDSP_Length bits = 0;
    while ((static_cast<size_t>(1) << bits) < powerOfTwo) bits++;
    return bits;
}

// max(0, x - local mean): removes loudness swells so only onsets remain.
std::vector<float> subtractLocalMean(const std::vector<float> &x, size_t halfWidth) {
    const size_t n = x.size();
    std::vector<double> prefix(n + 1, 0.0);
    for (size_t i = 0; i < n; i++) prefix[i + 1] = prefix[i] + x[i];
    std::vector<float> out(n);
    for (size_t i = 0; i < n; i++) {
        const size_t lo = i > halfWidth ? i - halfWidth : 0;
        const size_t hi = std::min(n, i + halfWidth + 1);
        const double mean = (prefix[hi] - prefix[lo]) / static_cast<double>(hi - lo);
        out[i] = std::max(0.0f, static_cast<float>(x[i] - mean));
    }
    return out;
}

double priorWeight(double bpmValue, const TempoOptions &o) {
    const double octaves = std::log2(bpmValue / o.priorCenterBpm) / o.priorWidthOctaves;
    return std::exp(-0.5 * octaves * octaves);
}

// Sub-sample position of the peak at index p (A[p-1] <= A[p] >= A[p+1]).
double parabolicPeak(const std::vector<double> &a, size_t p) {
    const double left = a[p - 1], mid = a[p], right = a[p + 1];
    const double denom = left - 2.0 * mid + right;
    if (denom >= 0.0) return static_cast<double>(p);
    const double offset = 0.5 * (left - right) / denom;
    return static_cast<double>(p) + std::clamp(offset, -0.5, 0.5);
}

} // namespace

// ---------------------------------------------------------------------------
// OnsetEnvelope
// ---------------------------------------------------------------------------

struct OnsetEnvelope::Impl {
    double sampleRate;
    size_t hop;
    size_t frameSize;
    size_t half;
    size_t fluxBins;
    size_t lowEnd, highStart;   // band edges in bins: [1, lowEnd), [lowEnd, highStart), [highStart, half)
    vDSP_Length log2n;
    FFTSetup fft = nullptr;

    std::vector<float> window, frame, real, imag, magnitude, logMag, prevLogMag;
    bool havePrevious = false;

    std::vector<float> pending;  // mono samples not yet consumed by a frame
    uint64_t samplesAdded = 0;
    std::vector<float> values;
    BandEnergies bands;

    explicit Impl(double rate) : sampleRate(rate > 0 ? rate : 44100.0) {
        hop = hopForRate(sampleRate);
        frameSize = hop * 4;
        half = frameSize / 2;
        log2n = log2Of(frameSize);
        fft = vDSP_create_fftsetup(log2n, kFFTRadix2);

        const double binHz = sampleRate / static_cast<double>(frameSize);
        fluxBins = std::min(half - 1, static_cast<size_t>(kMaxFluxHz / binHz));
        lowEnd = std::clamp<size_t>(static_cast<size_t>(std::ceil(kBandLowHz / binHz)), 2, half);
        highStart = std::clamp<size_t>(static_cast<size_t>(std::ceil(kBandHighHz / binHz)), lowEnd, half);

        window.resize(frameSize);
        vDSP_hann_window(window.data(), frameSize, vDSP_HANN_DENORM);
        frame.resize(frameSize);
        real.resize(half);
        imag.resize(half);
        magnitude.resize(half);
        logMag.resize(fluxBins);
        prevLogMag.resize(fluxBins);
    }

    ~Impl() {
        if (fft) vDSP_destroy_fftsetup(fft);
    }

    void processFrames() {
        size_t readPos = 0;
        while (pending.size() - readPos >= frameSize) {
            vDSP_vmul(pending.data() + readPos, 1, window.data(), 1, frame.data(), 1, frameSize);

            DSPSplitComplex split{real.data(), imag.data()};
            vDSP_ctoz(reinterpret_cast<const DSPComplex *>(frame.data()), 2, &split, 1, half);
            vDSP_fft_zrip(fft, &split, 1, log2n, FFT_FORWARD);
            split.imagp[0] = 0.0f;  // packed Nyquist; bin 0 is not used either
            vDSP_zvabs(&split, 1, magnitude.data(), 1, half);

            // Band energies from the unscaled magnitudes (bin 0 is DC)
            const size_t edges[4] = { 1, lowEnd, highStart, half };
            const float norm = 1.0f / (static_cast<float>(frameSize) * static_cast<float>(frameSize));
            for (int b = 0; b < 3; b++) {
                float energy = 0.0f;
                if (edges[b + 1] > edges[b]) vDSP_svesq(magnitude.data() + edges[b], 1, &energy, edges[b + 1] - edges[b]);
                bands[b].push_back(energy * norm);
            }

            const float scale = kCompression / static_cast<float>(frameSize);
            vDSP_vsmul(magnitude.data() + 1, 1, &scale, magnitude.data() + 1, 1, fluxBins);
            const int count = static_cast<int>(fluxBins);
            vvlog1pf(logMag.data(), magnitude.data() + 1, &count);

            float flux = 0.0f;
            if (havePrevious) {
                for (size_t k = 0; k < fluxBins; k++) {
                    const float rise = logMag[k] - prevLogMag[k];
                    if (rise > 0.0f) flux += rise;
                }
            }
            std::swap(logMag, prevLogMag);
            havePrevious = true;

            values.push_back(flux);
            readPos += hop;
        }
        if (readPos > 0) pending.erase(pending.begin(), pending.begin() + static_cast<std::ptrdiff_t>(readPos));
    }

    template <typename Sample>
    void append(const Sample *samples, size_t frames, unsigned channels) {
        if (!samples || frames == 0 || channels == 0) return;
        const size_t base = pending.size();
        pending.resize(base + frames);
        float *out = pending.data() + base;
        const double scale = 1.0 / static_cast<double>(channels);
        for (size_t i = 0; i < frames; i++) {
            const Sample *f = samples + i * channels;
            double sum = 0.0;
            for (unsigned c = 0; c < channels; c++) sum += static_cast<double>(f[c]);
            out[i] = static_cast<float>(sum * scale);
        }
        samplesAdded += frames;
        processFrames();
    }
};

OnsetEnvelope::OnsetEnvelope(double sampleRate) : m(std::make_unique<Impl>(sampleRate)) {}
OnsetEnvelope::~OnsetEnvelope() = default;

void OnsetEnvelope::addInterleaved(const float *samples, size_t frames, unsigned channels) {
    m->append(samples, frames, channels);
}

void OnsetEnvelope::addInterleaved(const double *samples, size_t frames, unsigned channels) {
    m->append(samples, frames, channels);
}

double OnsetEnvelope::framesPerSecond() const {
    return m->sampleRate / static_cast<double>(m->hop);
}

double OnsetEnvelope::secondsAdded() const {
    return static_cast<double>(m->samplesAdded) / m->sampleRate;
}

const std::vector<float> &OnsetEnvelope::values() const {
    return m->values;
}

const BandEnergies &OnsetEnvelope::bands() const {
    return m->bands;
}

double OnsetEnvelope::firstFrameSeconds() const {
    return static_cast<double>(m->frameSize) / 2.0 / m->sampleRate;
}

// ---------------------------------------------------------------------------
// estimateTempo
// ---------------------------------------------------------------------------

namespace {

// Mean over the track of each window's normalised autocorrelation.
// Returns an empty vector when no window has any onset energy.
std::vector<double> averageAutocorrelation(const std::vector<float> &novelty, size_t win) {
    const size_t n = novelty.size();
    size_t fftSize = 1;
    while (fftSize < 2 * win) fftSize <<= 1;
    const vDSP_Length log2n = log2Of(fftSize);
    const size_t half = fftSize / 2;

    FFTSetup fft = vDSP_create_fftsetup(log2n, kFFTRadix2);
    std::vector<float> taper(win), buffer(fftSize), real(half), imag(half), ac(fftSize);
    vDSP_hann_window(taper.data(), win, vDSP_HANN_NORM);

    std::vector<double> sum(win, 0.0);
    size_t used = 0;
    const size_t step = std::max<size_t>(1, win / 4);

    for (size_t start = 0; start + win <= n; start += step) {
        // Remove the window's mean first: the envelope is never negative, and
        // its mean alone would correlate at every lag, so noise would look
        // like a pulse.
        float mean = 0.0f;
        vDSP_meanv(novelty.data() + start, 1, &mean, win);
        const float negMean = -mean;
        std::fill(buffer.begin(), buffer.end(), 0.0f);
        vDSP_vsadd(novelty.data() + start, 1, &negMean, buffer.data(), 1, win);
        vDSP_vmul(buffer.data(), 1, taper.data(), 1, buffer.data(), 1, win);

        DSPSplitComplex split{real.data(), imag.data()};
        vDSP_ctoz(reinterpret_cast<const DSPComplex *>(buffer.data()), 2, &split, 1, half);
        vDSP_fft_zrip(fft, &split, 1, log2n, FFT_FORWARD);

        // Power spectrum. Bin 0 packs DC in realp and Nyquist in imagp.
        const float dc = real[0] * real[0];
        const float nyquist = imag[0] * imag[0];
        for (size_t k = 1; k < half; k++) {
            real[k] = real[k] * real[k] + imag[k] * imag[k];
            imag[k] = 0.0f;
        }
        real[0] = dc;
        imag[0] = nyquist;

        vDSP_fft_zrip(fft, &split, 1, log2n, FFT_INVERSE);
        vDSP_ztoc(&split, 1, reinterpret_cast<DSPComplex *>(ac.data()), 2, half);

        const double zeroLag = ac[0];
        if (!(zeroLag > 1e-12)) continue;  // silent stretch
        for (size_t lag = 0; lag < win; lag++) sum[lag] += ac[lag] / zeroLag;
        used++;
    }

    vDSP_destroy_fftsetup(fft);
    if (used == 0) return {};
    for (double &v : sum) v /= static_cast<double>(used);
    return sum;
}

} // namespace

TempoResult estimateTempo(const std::vector<float> &envelope, double fps, const TempoOptions &o) {
    TempoResult result;
    if (!(fps > 0.0) || !(o.minBpm > 0.0) || !(o.maxBpm > o.minBpm)) return result;
    const size_t n = envelope.size();
    if (static_cast<double>(n) < kMinimumSeconds * fps) return result;

    const auto meanHalfWidth = static_cast<size_t>(std::lround(0.5 * kLocalMeanSeconds * fps));
    const std::vector<float> novelty = subtractLocalMean(envelope, meanHalfWidth);

    const size_t win = std::min(n, static_cast<size_t>(std::lround(kWindowSeconds * fps)));
    const auto lagMin = std::max<size_t>(2, static_cast<size_t>(std::ceil(60.0 * fps / o.maxBpm)));
    const auto lagMax = static_cast<size_t>(std::floor(60.0 * fps / o.minBpm));
    if (lagMax + 2 >= win || lagMin > lagMax) return result;

    const std::vector<double> a = averageAutocorrelation(novelty, win);
    if (a.empty()) return result;

    size_t best = 0;
    double bestScore = 0.0;
    for (size_t lag = lagMin; lag <= lagMax; lag++) {
        const double score = a[lag] * priorWeight(60.0 * fps / static_cast<double>(lag), o);
        if (score > bestScore) {
            bestScore = score;
            best = lag;
        }
    }
    if (best == 0) return result;

    // The prior can tip the choice onto the shoulder of a peak; move to the
    // top of the peak it sits on before refining.
    while (best + 1 < win - 1 && a[best + 1] > a[best]) best++;
    while (best > 1 && a[best - 1] > a[best]) best--;

    // Weighted mean of period estimates from the peaks at k * period. The
    // k-th peak pins the period k times more precisely, hence weight * k.
    const double first = parabolicPeak(a, best);
    double weighted = 0.0, weights = 0.0;
    for (int k = 1; k <= kMaxHarmonic; k++) {
        const double centre = first * k;
        const auto lo = static_cast<size_t>(std::max(1.0, std::floor(centre - k)));
        const auto hi = static_cast<size_t>(std::min(static_cast<double>(win - 2), std::ceil(centre + k)));
        if (lo >= hi) break;
        size_t peak = lo;
        for (size_t i = lo; i <= hi; i++) {
            if (a[i] > a[peak]) peak = i;
        }
        if (peak == lo || peak == hi || a[peak] <= 0.0) continue;  // no peak inside the window
        const double period = parabolicPeak(a, peak) / k;
        if (std::fabs(period - first) > 0.03 * first) continue;
        weighted += period * a[peak] * k;
        weights += a[peak] * k;
    }
    const double period = weights > 0.0 ? weighted / weights : first;

    result.valid = true;
    result.bpm = 60.0 * fps / period;
    result.strength = std::clamp(a[best], 0.0, 1.0);
    return result;
}

} // namespace bpm
