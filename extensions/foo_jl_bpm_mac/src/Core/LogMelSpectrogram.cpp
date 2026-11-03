//
//  LogMelSpectrogram.cpp
//  foo_jl_bpm_mac
//

#include "LogMelSpectrogram.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>

namespace bpm {

namespace {

constexpr double kMelMinHz = 30.0;
constexpr double kMelMaxHz = 11000.0;
constexpr double kLogMultiplier = 1000.0;
constexpr size_t kHalfWindow = kMelFFT / 2;
constexpr size_t kSpectrumBins = kMelFFT / 2 + 1;

// Slaney's mel scale: linear below 1 kHz, logarithmic above
double hzToMel(double hz) {
    const double fsp = 200.0 / 3.0, minLogHz = 1000.0, minLogMel = minLogHz / fsp;
    const double logStep = std::log(6.4) / 27.0;
    return hz >= minLogHz ? minLogMel + std::log(hz / minLogHz) / logStep : hz / fsp;
}

double melToHz(double mel) {
    const double fsp = 200.0 / 3.0, minLogHz = 1000.0, minLogMel = minLogHz / fsp;
    const double logStep = std::log(6.4) / 27.0;
    return mel >= minLogMel ? minLogHz * std::exp(logStep * (mel - minLogMel)) : fsp * mel;
}

// Triangular filters as torchaudio's melscale_fbanks builds them (norm None):
// band m rises from point m to m + 1 and falls to m + 2, the points evenly
// spaced in mel between the band edges; [band][bin]
std::vector<double> melFilters() {
    std::vector<double> points(kMelBands + 2);
    const double lo = hzToMel(kMelMinHz), hi = hzToMel(kMelMaxHz);
    for (size_t i = 0; i < points.size(); i++) {
        points[i] = melToHz(lo + (hi - lo) * static_cast<double>(i) / static_cast<double>(kMelBands + 1));
    }
    std::vector<double> filters(kMelBands * kSpectrumBins, 0.0);
    for (size_t m = 0; m < kMelBands; m++) {
        const double left = points[m], centre = points[m + 1], right = points[m + 2];
        for (size_t k = 0; k < kSpectrumBins; k++) {
            const double f = kMelSampleRate / 2.0 * static_cast<double>(k) / static_cast<double>(kSpectrumBins - 1);
            const double up = (f - left) / (centre - left), down = (right - f) / (right - centre);
            filters[m * kSpectrumBins + k] = std::max(0.0, std::min(up, down));
        }
    }
    return filters;
}

} // namespace

struct LogMelSpectrogram::Impl {
    // Double precision: in bands with almost no energy log(1 + 1000 x)
    // magnifies float32 rounding to a few 1e-4, different for every FFT
    FFTSetupD fft = nullptr;
    vDSP_Length log2n = 10;
    std::vector<double> window, filters, frame, real, imag, magnitude, bands;
    std::vector<float> head;            // the first kHalfWindow + 1 samples, for the reflection at the start
    std::vector<float> buffer;          // samples from bufferStart on
    uint64_t bufferStart = 0;
    uint64_t received = 0;
    uint64_t nextFrame = 0;
    bool finished = false;
    std::vector<float> out;             // completed frames not yet taken

    Impl() {
        fft = vDSP_create_fftsetupD(log2n, kFFTRadix2);
        window.resize(kMelFFT);
        for (size_t n = 0; n < kMelFFT; n++) window[n] = 0.5 - 0.5 * std::cos(2.0 * M_PI * static_cast<double>(n) / kMelFFT);
        filters = melFilters();
        frame.resize(kMelFFT);
        real.resize(kHalfWindow);
        imag.resize(kHalfWindow);
        magnitude.resize(kSpectrumBins);
        bands.resize(kMelBands);
    }

    ~Impl() {
        if (fft) vDSP_destroy_fftsetupD(fft);
    }

    // Sample i of the padded piece (i may be negative or past the end):
    // reflected at both ends, without repeating the edge sample
    float sample(int64_t i) const {
        if (i < 0) i = -i;
        if (finished && i >= static_cast<int64_t>(received)) i = 2 * (static_cast<int64_t>(received) - 1) - i;
        if (i < static_cast<int64_t>(head.size())) return head[static_cast<size_t>(i)];
        return buffer[static_cast<size_t>(static_cast<uint64_t>(i) - bufferStart)];
    }

    void computeFrame(uint64_t k) {
        const int64_t centre = static_cast<int64_t>(k * kMelHop);
        for (size_t n = 0; n < kMelFFT; n++) {
            frame[n] = sample(centre - static_cast<int64_t>(kHalfWindow) + static_cast<int64_t>(n)) * window[n];
        }
        DSPDoubleSplitComplex split{ real.data(), imag.data() };
        vDSP_ctozD(reinterpret_cast<const DSPDoubleComplex *>(frame.data()), 2, &split, 1, kHalfWindow);
        vDSP_fft_zripD(fft, &split, 1, log2n, FFT_FORWARD);
        // vDSP's forward real FFT is twice the DFT, DC and Nyquist packed in
        // bin 0; magnitudes over sqrt(N) ("frame_length" normalisation)
        const double scale = 0.5 / std::sqrt(static_cast<double>(kMelFFT));
        magnitude[0] = std::fabs(real[0]) * scale;
        magnitude[kHalfWindow] = std::fabs(imag[0]) * scale;
        for (size_t b = 1; b < kHalfWindow; b++) magnitude[b] = std::hypot(real[b], imag[b]) * scale;
        // Mel bands: filters (bands x bins) times magnitudes
        vDSP_mmulD(filters.data(), 1, magnitude.data(), 1, bands.data(), 1, kMelBands, 1, kSpectrumBins);
        for (double v : bands) out.push_back(static_cast<float>(std::log1p(kLogMultiplier * v)));
    }

    // Frames whose window lies inside what has arrived (and, for the first
    // ones, past the reflected start), then samples no frame needs again
    void processFrames() {
        if (received <= kHalfWindow) return;   // the start's reflection needs kHalfWindow + 1 samples
        // Centred frames: a piece of n samples has 1 + n / hop of them
        const uint64_t total = 1 + received / kMelHop;
        while (finished ? nextFrame < total : nextFrame * kMelHop + kHalfWindow <= received) {
            computeFrame(nextFrame++);
        }
        const uint64_t keepFrom = nextFrame * kMelHop > kHalfWindow ? nextFrame * kMelHop - kHalfWindow : 0;
        if (keepFrom > bufferStart) {
            const size_t drop = static_cast<size_t>(std::min<uint64_t>(keepFrom - bufferStart, buffer.size()));
            buffer.erase(buffer.begin(), buffer.begin() + static_cast<std::ptrdiff_t>(drop));
            bufferStart += drop;
        }
    }
};

LogMelSpectrogram::LogMelSpectrogram() : m(std::make_unique<Impl>()) {}
LogMelSpectrogram::~LogMelSpectrogram() = default;

void LogMelSpectrogram::add(const float *samples, size_t count) {
    if (m->finished || count == 0) return;
    for (size_t i = 0; i < count && m->head.size() <= kHalfWindow; i++) m->head.push_back(samples[i]);
    m->buffer.insert(m->buffer.end(), samples, samples + count);
    m->received += count;
    m->processFrames();
}

void LogMelSpectrogram::finish() {
    if (m->finished) return;
    m->finished = true;
    m->processFrames();
}

size_t LogMelSpectrogram::pendingFrames() const { return m->out.size() / kMelBands; }

std::vector<float> LogMelSpectrogram::take() {
    std::vector<float> frames;
    frames.swap(m->out);
    return frames;
}

uint64_t LogMelSpectrogram::framesProduced() const { return m->nextFrame; }

} // namespace bpm
