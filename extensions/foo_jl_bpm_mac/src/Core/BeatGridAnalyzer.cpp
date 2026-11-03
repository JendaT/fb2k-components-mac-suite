//
//  BeatGridAnalyzer.cpp
//  foo_jl_bpm_mac
//

#include "BeatGridAnalyzer.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace bpm {

namespace {

// Stage 3 (Ellis 2007): how strongly the tracker holds the tempo, and the
// width of the local score's Gaussian as a fraction of the beat period
constexpr double kTightness = 100.0;
constexpr double kLocalScoreWidth = 32.0;
// Leading frames under this share of the strongest local score start no chain
constexpr double kChainThreshold = 0.01;
// The last beat: a local maximum of the cumulative score at least this share
// of the median of all of them
constexpr double kLastBeatShare = 0.5;
// Leading and trailing beats at or under this share of the RMS of the
// smoothed beat scores are trimmed
constexpr double kTrimShare = 0.5;
// Sub-frame refinement looks for the envelope peak this many frames around
constexpr long kRefineFrames = 2;

double median(std::vector<double> v) {
    if (v.empty()) return 0.0;
    const size_t mid = v.size() / 2;
    std::nth_element(v.begin(), v.begin() + static_cast<std::ptrdiff_t>(mid), v.end());
    const double upper = v[mid];
    if (v.size() % 2) return upper;
    return 0.5 * (upper + *std::max_element(v.begin(), v.begin() + static_cast<std::ptrdiff_t>(mid)));
}

// Peak of y around index m to sub-sample precision (m is a local maximum)
double parabola(const std::vector<double> &y, size_t m) {
    if (m == 0 || m + 1 >= y.size()) return static_cast<double>(m);
    const double denom = y[m - 1] - 2.0 * y[m] + y[m + 1];
    if (!(denom < 0.0)) return static_cast<double>(m);
    return static_cast<double>(m) + std::clamp(0.5 * (y[m - 1] - y[m + 1]) / denom, -0.5, 0.5);
}

} // namespace

namespace detail {

double applyHints(double bpm, const BeatGridHints &hints) {
    for (double reference : { hints.tagBpm, hints.tidalBpm }) {
        if (!(reference > 0.0)) continue;
        for (double factor : { 1.0, 0.5, 2.0 }) {
            if (std::fabs(bpm * factor - reference) <= kHintTolerance * reference) return bpm * factor;
        }
    }
    return bpm;
}

std::vector<double> trackBeats(const std::vector<float> &envelope, double fps, double bpm) {
    const size_t n = envelope.size();
    if (n < 4 || !(fps > 0.0) || !(bpm > 0.0)) return {};
    const long period = std::max(1L, std::lround(fps * 60.0 / bpm));

    // 1. The envelope over its standard deviation
    double mean = 0.0;
    for (float v : envelope) mean += v;
    mean /= static_cast<double>(n);
    double var = 0.0;
    for (float v : envelope) var += (v - mean) * (v - mean);
    const double sd = std::sqrt(var / static_cast<double>(n - 1));
    if (!(sd > 0.0)) return {};
    std::vector<double> onset(n);
    for (size_t i = 0; i < n; i++) onset[i] = envelope[i] / sd;

    // 2. Local score: the onsets under a Gaussian a beat wide on each side
    std::vector<double> window(static_cast<size_t>(2 * period + 1));
    for (long t = -period; t <= period; t++) {
        const double x = static_cast<double>(t) * kLocalScoreWidth / static_cast<double>(period);
        window[static_cast<size_t>(t + period)] = std::exp(-0.5 * x * x);
    }
    std::vector<double> local(n, 0.0);
    for (size_t i = 0; i < n; i++) {
        double sum = 0.0;
        const long lo = std::max(-period, static_cast<long>(i) - static_cast<long>(n) + 1);
        const long hi = std::min(period, static_cast<long>(i));
        for (long t = lo; t <= hi; t++) sum += onset[i - static_cast<size_t>(t)] * window[static_cast<size_t>(t + period)];
        local[i] = sum;
    }
    const double localMax = *std::max_element(local.begin(), local.end());

    // 3. Cumulative score: each frame's local score plus the best earlier
    // beat between half and two periods back, penalised by how far that
    // interval is from the period (log ratio). Back-links rebuild the chain;
    // -1 starts one.
    const long minGap = std::max(1L, std::lround(period / 2.0)), maxGap = 2 * period;
    std::vector<double> penalty(static_cast<size_t>(maxGap + 1), 0.0);
    for (long gap = minGap; gap <= maxGap; gap++) {
        const double r = std::log(static_cast<double>(gap) / static_cast<double>(period));
        penalty[static_cast<size_t>(gap)] = -kTightness * r * r;
    }
    std::vector<double> cumulative(n);
    std::vector<long> back(n, -1);
    bool started = false;
    for (size_t i = 0; i < n; i++) {
        double best = -std::numeric_limits<double>::infinity();
        long bestFrame = -1;
        for (long gap = minGap; gap <= maxGap; gap++) {
            const long j = static_cast<long>(i) - gap;
            const double candidate = penalty[static_cast<size_t>(gap)] + (j >= 0 ? cumulative[static_cast<size_t>(j)] : 0.0);
            if (candidate > best) {
                best = candidate;
                bestFrame = j;
            }
        }
        cumulative[i] = local[i] + best;
        if (!started && local[i] < kChainThreshold * localMax) {
            back[i] = -1;
        } else {
            back[i] = bestFrame;
            started = true;
        }
    }

    // 4. The last beat, then back along the links
    std::vector<size_t> maxima;
    for (size_t i = 1; i + 1 < n; i++) {
        if (cumulative[i] > cumulative[i - 1] && cumulative[i] >= cumulative[i + 1]) maxima.push_back(i);
    }
    if (maxima.empty()) return {};
    std::vector<double> peakScores;
    for (size_t i : maxima) peakScores.push_back(cumulative[i]);
    const double lastThreshold = kLastBeatShare * median(peakScores);
    long last = -1;
    for (size_t k = maxima.size(); k-- > 0;) {
        if (cumulative[maxima[k]] >= lastThreshold) {
            last = static_cast<long>(maxima[k]);
            break;
        }
    }
    if (last < 0) return {};
    std::vector<size_t> beats;
    for (long b = last; b >= 0; b = back[static_cast<size_t>(b)]) beats.push_back(static_cast<size_t>(b));
    std::reverse(beats.begin(), beats.end());

    // 5. Trim weak beats at both ends: beat scores smoothed by a 5-point Hann
    if (beats.size() >= 3) {
        const double hann[5] = { 0.25, 0.75, 1.0, 0.75, 0.25 };
        std::vector<double> smooth(beats.size(), 0.0);
        for (size_t k = 0; k < beats.size(); k++) {
            for (int t = -2; t <= 2; t++) {
                const long idx = static_cast<long>(k) + t;
                if (idx >= 0 && idx < static_cast<long>(beats.size())) smooth[k] += local[beats[static_cast<size_t>(idx)]] * hann[t + 2];
            }
        }
        double meanSquare = 0.0;
        for (double v : smooth) meanSquare += v * v;
        const double threshold = kTrimShare * std::sqrt(meanSquare / static_cast<double>(smooth.size()));
        size_t first = 0, end = beats.size();
        while (first < end && smooth[first] <= threshold) first++;
        while (end > first && smooth[end - 1] <= threshold) end--;
        beats = std::vector<size_t>(beats.begin() + static_cast<std::ptrdiff_t>(first),
                                    beats.begin() + static_cast<std::ptrdiff_t>(end));
    }

    // 6. Each beat on the envelope peak near it, to sub-frame precision
    std::vector<double> refined;
    refined.reserve(beats.size());
    for (size_t b : beats) {
        const size_t lo = b >= static_cast<size_t>(kRefineFrames) ? b - kRefineFrames : 0;
        const size_t hi = std::min(n - 1, b + kRefineFrames);
        size_t peak = b;
        for (size_t i = lo; i <= hi; i++) {
            if (onset[i] > onset[peak]) peak = i;
        }
        refined.push_back(parabola(onset, peak));
    }
    return refined;
}

namespace {

// Least-squares line through the beats l..r against their index
struct Line {
    double first = 0.0, length = 0.0;   // fitted time of beat l, beat length
};
Line fitLine(const std::vector<double> &b, size_t l, size_t r) {
    const double n = static_cast<double>(r - l + 1);
    double si = 0.0, sb = 0.0, sii = 0.0, sib = 0.0;
    for (size_t i = l; i <= r; i++) {
        const double x = static_cast<double>(i - l), y = b[i] - b[l];
        si += x; sb += y; sii += x * x; sib += x * y;
    }
    const double denom = n * sii - si * si;
    Line line;
    line.length = denom > 0.0 ? (n * sib - si * sb) / denom : 0.0;
    line.first = b[l] + (sb - line.length * si) / n;
    return line;
}

} // namespace

bool fitsOneGrid(const std::vector<double> &b, size_t l, size_t r) {
    if (r <= l || r >= b.size()) return false;
    if (r == l + 1) return true;
    const Line line = fitLine(b, l, r);
    if (!(line.length > 0.0)) return false;
    // The beat after the start, predicted from it, must sit on the grid
    if (std::fabs(b[l + 1] - b[l] - line.length) > kBeatTolerance) return false;
    int outliers = 0;
    double errorSum = 0.0;
    for (size_t i = l; i <= r; i++) {
        const double error = line.first + static_cast<double>(i - l) * line.length - b[i];
        errorSum += error;
        if (std::fabs(error) > kBeatTolerance) {
            // The region's first beats must sit on the grid
            if (i <= l + 1 || ++outliers > kMaxOutliers) return false;
        }
        if (std::fabs(errorSum) > kDriftLimit) return false;   // steady drift to one side
    }
    return true;
}

std::vector<BeatRegion> constantRegions(const std::vector<double> &b) {
    std::vector<BeatRegion> regions;
    if (b.size() < 2) return regions;
    const size_t last = b.size() - 1;
    // From each start, the furthest end that still fits one grid; most
    // spans that don't fit fail within a few beats, which keeps this fast
    for (size_t l = 0; l < last;) {
        size_t r = last;
        while (r > l + 1 && !fitsOneGrid(b, l, r)) r--;
        const double length = r > l + 1 ? fitLine(b, l, r).length : b[r] - b[l];
        BeatRegion region;
        region.startSeconds = b[l];
        region.beatSeconds = length;
        region.beatCount = static_cast<uint32_t>(r - l);
        regions.push_back(region);
        l = r;
    }
    return regions;
}

double snapBpm(double minBpm, double centerBpm, double maxBpm) {
    auto inside = [&](double v) { return v >= minBpm && v <= maxBpm; };
    std::vector<double> candidates = { std::round(centerBpm) };
    if (centerBpm < 85.0) candidates.push_back(std::round(centerBpm * 2.0) / 2.0);
    if (centerBpm > 127.0) candidates.push_back(std::round(centerBpm * 1.5) / 1.5);
    candidates.push_back(std::round(centerBpm * 3.0) / 3.0);
    candidates.push_back(std::round(centerBpm * 12.0) / 12.0);
    for (double v : candidates) {
        if (inside(v)) return v;
    }
    return centerBpm;
}

MasterGrid masterGrid(const std::vector<BeatRegion> &regions, const std::vector<double> &beats) {
    MasterGrid out;
    size_t anchor = regions.size();
    double longest = 0.0;
    for (size_t i = 0; i < regions.size(); i++) {
        const double length = regions[i].beatCount * regions[i].beatSeconds;
        if (regions[i].stable() && length > longest) {
            longest = length;
            anchor = i;
        }
    }
    if (anchor == regions.size()) return out;

    // The span the grid is fitted to: [start, end] over `count` beats
    double start = regions[anchor].startSeconds, end = regions[anchor].endSeconds();
    uint32_t count = regions[anchor].beatCount;
    double length = regions[anchor].beatSeconds;
    auto tolerance = [](uint32_t beatCount) { return kBeatTolerance / static_cast<double>(beatCount); };

    // Joins a region if both tempos agree within their tolerances and the
    // joined span holds one unambiguous whole number of beats whose length
    // stays within the span's tolerance (same tempo and same phase)
    auto join = [&](const BeatRegion &g, double newStart, double newEnd) {
        const double lo = std::max(length - tolerance(count), g.beatSeconds - tolerance(g.beatCount));
        const double hi = std::min(length + tolerance(count), g.beatSeconds + tolerance(g.beatCount));
        if (!(lo < hi) || !(lo > 0.0)) return false;
        const double span = newEnd - newStart;
        const long most = std::lround(span / lo), fewest = std::lround(span / hi);
        if (most != fewest || most <= 0) return false;
        const double joined = span / static_cast<double>(most);
        if (std::fabs(joined - length) > tolerance(count)) return false;
        start = newStart;
        end = newEnd;
        count = static_cast<uint32_t>(most);
        length = joined;
        return true;
    };
    // Backwards, from the start of the track: the furthest region first
    for (size_t i = 0; i < anchor; i++) {
        if (regions[i].stable() && join(regions[i], regions[i].startSeconds, end)) break;
    }
    // Then forwards, from the end of the track
    for (size_t i = regions.size(); i-- > anchor + 1;) {
        if (regions[i].stable() && join(regions[i], start, regions[i].endSeconds())) break;
    }

    // BPM: the roundest value inside the span's tolerance
    const double minBpm = 60.0 / (length + tolerance(count));
    const double maxBpm = 60.0 / (length - tolerance(count));
    out.bpm = snapBpm(minBpm, 60.0 / length, maxBpm);
    const double beat = 60.0 / out.bpm;

    // Phase: the mean offset of the raw beats near the snapped grid
    double offsetSum = 0.0;
    size_t near = 0;
    for (double t : beats) {
        const double offset = t - (start + std::round((t - start) / beat) * beat);
        if (std::fabs(offset) <= kBeatTolerance) {
            offsetSum += offset;
            near++;
        }
    }
    const double phase = start + (near ? offsetSum / static_cast<double>(near) : 0.0);
    out.anchorSeconds = phase - std::floor(phase / beat) * beat;
    out.valid = true;
    return out;
}

} // namespace detail

namespace {

// Per-bar statistics of the raw beats against the master grid, the pulse
// of each bar, and where stable regions off the grid begin
std::vector<BarStat> barStats(const BeatGrid &grid, const std::vector<float> &envelope, double fps,
                              double firstFrameSeconds, double durationSeconds) {
    const double beat = grid.beatSeconds(), barLength = beat * kBeatsPerBar;
    if (!(beat > 0.0) || !(durationSeconds > grid.anchorSeconds)) return {};
    const size_t barCount = static_cast<size_t>(std::ceil((durationSeconds - grid.anchorSeconds) / barLength));
    std::vector<BarStat> bars(barCount);

    std::vector<std::vector<double>> offsets(barCount);
    std::vector<uint8_t> matchedMask(barCount, 0);
    for (double t : grid.beats) {
        const long j = std::lround((t - grid.anchorSeconds) / beat);
        if (j < 0) continue;
        const size_t bar = static_cast<size_t>(j) / kBeatsPerBar;
        if (bar >= barCount) continue;
        const double offset = t - grid.beatTime(j);
        offsets[bar].push_back(offset);
        if (std::fabs(offset) <= kBeatTolerance) matchedMask[bar] |= static_cast<uint8_t>(1u << (j % kBeatsPerBar));
    }
    for (size_t i = 0; i < barCount; i++) {
        const double ms = std::clamp(std::round(median(offsets[i]) * 1000.0), -127.0, 127.0);
        bars[i].offset_ms = static_cast<int8_t>(ms);
        bars[i].matched = static_cast<uint8_t>(__builtin_popcount(matchedMask[i]));
    }

    // Pulse: mean envelope over the bar against the median bar
    std::vector<double> means(barCount, 0.0);
    for (size_t i = 0; i < barCount; i++) {
        const double t0 = grid.anchorSeconds + i * barLength, t1 = t0 + barLength;
        auto frameAt = [&](double t) {
            const double k = std::ceil((t - kOnsetCorrection - firstFrameSeconds) * fps);
            return static_cast<size_t>(std::clamp(k, 0.0, static_cast<double>(envelope.size())));
        };
        const size_t k0 = frameAt(t0), k1 = frameAt(t1);
        double sum = 0.0;
        for (size_t k = k0; k < k1; k++) sum += envelope[k];
        means[i] = k1 > k0 ? sum / static_cast<double>(k1 - k0) : 0.0;
    }
    const double typical = median(means);
    for (size_t i = 0; i < barCount; i++) {
        const double level = typical > 0.0 ? kPulseUnit * means[i] / typical : (means[i] > 0.0 ? 255.0 : 0.0);
        bars[i].pulse = static_cast<uint8_t>(std::clamp(std::round(level), 0.0, 255.0));
    }

    // Where one grid gives way to another: a stable region whose first beat
    // is off the previous stable region's grid, or whose tempo steps. Splits
    // within one grid (jitter) and gradual ramps meet on a shared beat with
    // small steps and are not flagged.
    const BeatRegion *previous = nullptr;
    for (const BeatRegion &g : grid.regions) {
        if (!g.stable()) continue;
        if (previous) {
            const double gap = g.startSeconds - previous->endSeconds();
            const double phase = gap - std::round(gap / previous->beatSeconds) * previous->beatSeconds;
            const bool step = std::fabs(g.beatSeconds - previous->beatSeconds) > kTempoStep * previous->beatSeconds;
            if (std::fabs(phase) > kBeatTolerance || step) {
                const long j = std::max(0L, std::lround((g.startSeconds - grid.anchorSeconds) / beat));
                bars[std::min(barCount - 1, static_cast<size_t>(j) / kBeatsPerBar)].flags |= kBarRegionStart;
            }
        }
        previous = &g;
    }
    return bars;
}

// Regions where many beats carry almost no onset energy (the tracker running
// through a silence or a beatless stretch, or re-syncing as it ends) neither
// anchor the grid nor mark where a new one begins
void markQuietRegions(std::vector<BeatRegion> &regions, const std::vector<double> &beats,
                      const std::vector<float> &envelope, double fps, double firstFrameSeconds) {
    if (envelope.empty() || beats.empty()) return;
    auto strength = [&](double t) {
        const long k = std::lround((t - kOnsetCorrection - firstFrameSeconds) * fps);
        float best = 0.0f;
        for (long i = k - 2; i <= k + 2; i++) {
            if (i >= 0 && i < static_cast<long>(envelope.size())) best = std::max(best, envelope[static_cast<size_t>(i)]);
        }
        return static_cast<double>(best);
    };
    std::vector<double> all;
    for (double t : beats) all.push_back(strength(t));
    const double typical = median(all);
    size_t next = 0;
    for (BeatRegion &g : regions) {
        size_t count = 0, weak = 0;
        const double end = g.endSeconds() + 1e-6;
        while (next < beats.size() && beats[next] < g.startSeconds - 1e-6) next++;
        for (size_t k = next; k < beats.size() && beats[k] <= end; k++) {
            count++;
            weak += all[k] < kNoPulseLevel * typical;
        }
        g.quiet = count > 0 && static_cast<double>(weak) > kQuietShare * static_cast<double>(count);
    }
}

} // namespace

BeatGrid buildBeatGrid(const RawBeats &raw, const std::vector<float> &envelope, double fps,
                       double firstFrameSeconds, double durationSeconds) {
    BeatGrid grid;
    grid.source = raw.source;
    grid.beats = raw.beats;
    grid.regions = detail::constantRegions(raw.beats);
    markQuietRegions(grid.regions, raw.beats, envelope, fps, firstFrameSeconds);
    const detail::MasterGrid master = detail::masterGrid(grid.regions, raw.beats);
    if (!master.valid) return grid;
    grid.bpm = master.bpm;
    grid.anchorSeconds = master.anchorSeconds;
    grid.bars = barStats(grid, envelope, fps, firstFrameSeconds, durationSeconds);
    grid.valid = !grid.bars.empty();
    return grid;
}

BeatGrid analyseBeatGrid(const std::vector<float> &envelope, const BandEnergies &bands, double fps,
                         double firstFrameSeconds, double durationSeconds, const BeatGridHints &hints) {
    (void)bands;   // stage 6
    const TempoResult tempo = estimateTempo(envelope, fps);
    if (!tempo.valid) return BeatGrid();
    const double bpmEstimate = detail::applyHints(tempo.bpm, hints);

    RawBeats raw;
    for (double frame : detail::trackBeats(envelope, fps, bpmEstimate)) {
        raw.beats.push_back(firstFrameSeconds + frame / fps + kOnsetCorrection);
    }
    BeatGrid grid = buildBeatGrid(raw, envelope, fps, firstFrameSeconds, durationSeconds);
    grid.tempoStrength = static_cast<float>(tempo.strength);
    grid.uncertain = tempo.strength < kUncertainStrength;
    return grid;
}

} // namespace bpm
