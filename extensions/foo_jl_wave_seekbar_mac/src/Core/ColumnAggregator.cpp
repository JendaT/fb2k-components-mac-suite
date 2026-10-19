//
//  ColumnAggregator.cpp
//  foo_wave_seekbar_mac
//

#include "ColumnAggregator.h"
#include "TrackAnalyzer.h"
#include <algorithm>
#include <cmath>

namespace analysis {

namespace {
    const size_t kShortTermHalf = 15;      // 3 s window, centred: 15 hops each side
    const size_t kMomentaryHalf = 2;       // 400 ms window, centred
    const size_t kTintHalf = 50;           // spectral balance over 10 s, centred: sections, not beats
    const size_t kMinReadoutHops = 4;      // correlation and bands over at least 400 ms
    const double kSilencePower = 1e-10;    // -100 dB

    float powerDb(double power) {
        return power > 0.0 ? (float)(10.0 * std::log10(power)) : -INFINITY;
    }

    // Mean of v over the hops [center - half, center + half), clamped to the track
    std::vector<double> centredMeans(const std::vector<float>& v, size_t half) {
        const size_t n = v.size();
        std::vector<double> prefix(n + 1, 0.0);
        for (size_t i = 0; i < n; ++i) prefix[i + 1] = prefix[i] + v[i];
        std::vector<double> means(n);
        for (size_t j = 0; j < n; ++j) {
            const size_t lo = j > half ? j - half : 0;
            const size_t hi = std::min(n, j + half);
            means[j] = (prefix[hi] - prefix[lo]) / std::max<size_t>(1, hi - lo);
        }
        return means;
    }
}

Columns aggregateColumns(const WaveformData& data, size_t columns) {
    Columns out;
    if (!data.isValid() || columns == 0) return out;

    const uint32_t chans = data.channelCount;
    const size_t blocks = data.blockCount(), hops = data.hopCount();
    const double totalFrames = data.duration * data.sampleRate;
    out.count = columns;
    out.channels = chans;
    for (uint32_t ch = 0; ch < chans; ++ch) {
        out.min[ch].resize(columns);
        out.max[ch].resize(columns);
        out.rms[ch].resize(columns);
        out.level[ch].resize(columns);
        out.momentary[ch].resize(columns);
    }
    out.lufs.resize(columns);
    out.peakDb.resize(columns);
    out.crestDb.resize(columns);
    out.correlation.resize(columns);
    for (auto& b : out.bandShare) b.resize(columns);
    for (auto& b : out.tintShare) b.resize(columns);

    // Short-term powers per hop, per channel and summed
    std::vector<double> shortTerm[2];
    std::vector<double> momentary[2];
    for (uint32_t ch = 0; ch < chans; ++ch) {
        shortTerm[ch] = centredMeans(data.hopKms[ch], kShortTermHalf);
        momentary[ch] = centredMeans(data.hopKms[ch], kMomentaryHalf);
    }
    std::vector<double> tintBands[3];
    for (int b = 0; b < 3; ++b) tintBands[b] = centredMeans(data.hopBand[b], kTintHalf);

    const double framesPerColumn = totalFrames / columns;
    const double blocksPerColumn = framesPerColumn / data.blockFrames;

    for (size_t c = 0; c < columns; ++c) {
        const double f0 = c * framesPerColumn, f1 = (c + 1) * framesPerColumn;

        // --- Sample envelope from fine blocks ---
        double sumSq = 0.0;
        float peak = 0.0f;
        for (uint32_t ch = 0; ch < chans; ++ch) {
            float mn, mx, rms;
            if (blocksPerColumn >= 1.0) {
                const size_t b0 = std::min(blocks - 1, (size_t)(f0 / data.blockFrames));
                const size_t b1 = std::min(blocks, std::max(b0 + 1, (size_t)std::ceil(f1 / data.blockFrames)));
                mn = 0.0f; mx = 0.0f;
                double ms = 0.0;
                for (size_t b = b0; b < b1; ++b) {
                    mn = std::min(mn, data.blockMin[ch][b]);
                    mx = std::max(mx, data.blockMax[ch][b]);
                    ms += (double)data.blockRms[ch][b] * data.blockRms[ch][b];
                }
                rms = (float)std::sqrt(ms / (b1 - b0));
            } else {
                // Narrower than a block: interpolate between block centres
                const double t = std::clamp((f0 + f1) * 0.5 / data.blockFrames - 0.5, 0.0, (double)(blocks - 1));
                const size_t i0 = (size_t)t, i1 = std::min(blocks - 1, i0 + 1);
                const float f = (float)(t - i0);
                auto lerp = [&](const std::vector<float>& v) { return v[i0] + (v[i1] - v[i0]) * f; };
                mn = lerp(data.blockMin[ch]);
                mx = lerp(data.blockMax[ch]);
                const float r0 = data.blockRms[ch][i0], r1 = data.blockRms[ch][i1];
                rms = std::sqrt(r0 * r0 + (r1 * r1 - r0 * r0) * f);
            }
            out.min[ch][c] = mn;
            out.max[ch][c] = mx;
            out.rms[ch][c] = std::min(rms, std::max(-mn, mx));   // RMS never exceeds the peak
            peak = std::max(peak, std::max(-mn, mx));
            sumSq += (double)out.rms[ch][c] * out.rms[ch][c];
        }
        const double rmsPower = sumSq / chans;
        out.peakDb[c] = peak > 0.0f ? 20.0f * std::log10(peak) : NAN;
        out.crestDb[c] = (peak > 0.0f && rmsPower > kSilencePower)
            ? out.peakDb[c] - powerDb(rmsPower) : NAN;

        // --- Hop-based values ---
        size_t h0 = std::min(hops - 1, (size_t)(f0 / data.hopFrames));
        size_t h1 = std::min(hops, std::max(h0 + 1, (size_t)std::ceil(f1 / data.hopFrames)));

        // Short-term and momentary levels: the loudest hop in the column
        double loudest = 0.0, loudestCh[2] = { 0.0, 0.0 }, momentaryCh[2] = { 0.0, 0.0 };
        for (size_t h = h0; h < h1; ++h) {
            double sum = 0.0;
            for (uint32_t ch = 0; ch < chans; ++ch) {
                loudestCh[ch] = std::max(loudestCh[ch], shortTerm[ch][h]);
                momentaryCh[ch] = std::max(momentaryCh[ch], momentary[ch][h]);
                sum += shortTerm[ch][h];
            }
            loudest = std::max(loudest, sum);
        }
        for (uint32_t ch = 0; ch < chans; ++ch) {
            out.level[ch][c] = powerDb(loudestCh[ch]);
            out.momentary[ch][c] = powerDb(momentaryCh[ch]);
        }
        out.lufs[c] = loudest > kSilencePower ? loudnessOf(loudest) : NAN;

        // Spectral balance around the column's centre
        {
            const size_t centre = (h0 + h1) / 2;
            const double total = tintBands[0][centre] + tintBands[1][centre] + tintBands[2][centre];
            for (int b = 0; b < 3; ++b) {
                out.tintShare[b][c] = total > kSilencePower ? (float)(tintBands[b][centre] / total) : NAN;
            }
        }

        // Correlation and bands: widen narrow columns to 400 ms around the centre
        if (h1 - h0 < kMinReadoutHops) {
            const size_t mid = (h0 + h1) / 2;
            h0 = mid >= kMinReadoutHops / 2 ? mid - kMinReadoutHops / 2 : 0;
            h1 = std::min(hops, h0 + kMinReadoutHops);
        }
        if (chans == 2) {
            double lr = 0.0, ll = 0.0, rr = 0.0;
            for (size_t h = h0; h < h1; ++h) {
                lr += data.hopLR[h];
                ll += data.hopMs[0][h];
                rr += data.hopMs[1][h];
            }
            const double norm = std::sqrt(ll * rr);
            out.correlation[c] = norm > kSilencePower * (h1 - h0)
                ? (float)std::clamp(lr / norm, -1.0, 1.0) : NAN;
        } else {
            out.correlation[c] = 1.0f;
        }

        double band[3] = { 0.0, 0.0, 0.0 };
        for (size_t h = h0; h < h1; ++h) {
            for (int b = 0; b < 3; ++b) band[b] += data.hopBand[b][h];
        }
        const double total = band[0] + band[1] + band[2];
        for (int b = 0; b < 3; ++b) {
            out.bandShare[b][c] = total > kSilencePower * (h1 - h0) ? (float)(band[b] / total) : NAN;
        }
    }
    return out;
}

Columns mixdown(const Columns& in) {
    if (in.channels != 2) return in;
    Columns out = in;
    out.channels = 1;
    for (size_t c = 0; c < in.count; ++c) {
        out.min[0][c] = std::min(in.min[0][c], in.min[1][c]);
        out.max[0][c] = std::max(in.max[0][c], in.max[1][c]);
        out.rms[0][c] = std::sqrt((in.rms[0][c] * in.rms[0][c] + in.rms[1][c] * in.rms[1][c]) * 0.5f);
        auto powerMean = [](float a, float b) {
            return powerDb((std::pow(10.0, a / 10.0) + std::pow(10.0, b / 10.0)) * 0.5);
        };
        out.level[0][c] = powerMean(in.level[0][c], in.level[1][c]);
        out.momentary[0][c] = powerMean(in.momentary[0][c], in.momentary[1][c]);
    }
    for (auto* v : { &out.min[1], &out.max[1], &out.rms[1], &out.level[1], &out.momentary[1] }) v->clear();
    return out;
}

} // namespace analysis
