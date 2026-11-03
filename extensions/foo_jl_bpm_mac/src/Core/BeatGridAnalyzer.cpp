//
//  BeatGridAnalyzer.cpp
//  foo_jl_bpm_mac
//

#include "BeatGridAnalyzer.h"

#include <algorithm>
#include <array>
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
    // From each start, the furthest end that still fits one grid: the span
    // doubles while it fits, then the end is bisected between the last fit
    // and the first failure (shrinking one beat at a time from the end took
    // seconds on an hour-long mix with many tempo changes)
    for (size_t l = 0; l < last;) {
        size_t good = l + 1, bad = last + 1;   // one interval always fits
        for (size_t step = kMinStableBeats;; step *= 2) {
            const size_t r = std::min(last, good + step);
            if (!fitsOneGrid(b, l, r)) {
                bad = r;
                break;
            }
            good = r;
            if (r == last) break;
        }
        while (bad - good > 1) {
            const size_t mid = good + (bad - good) / 2;
            if (fitsOneGrid(b, l, mid)) good = mid;
            else bad = mid;
        }
        const size_t r = good;
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

    // The whole track's beats on this grid refine it: a straight line
    // through every beat within the tolerance (beat index against time), the
    // BPM snapped again within that span's tolerance. The anchor region and
    // its extensions alone can leave a tempo error that adds up to tens of
    // milliseconds over a long track.
    {
        std::vector<double> js, ts;
        for (double t : beats) {
            const double k = std::round((t - out.anchorSeconds) / beat);
            if (std::fabs(t - (out.anchorSeconds + k * beat)) <= kBeatTolerance) {
                js.push_back(k);
                ts.push_back(t);
            }
        }
        if (js.size() >= kMinStableBeats) {
            const double n = static_cast<double>(js.size());
            double sj = 0.0, st = 0.0, sjj = 0.0, sjt = 0.0;
            for (size_t i = 0; i < js.size(); i++) {
                sj += js[i]; st += ts[i]; sjj += js[i] * js[i]; sjt += js[i] * ts[i];
            }
            const double denom = n * sjj - sj * sj;
            const double fitted = denom > 0.0 ? (n * sjt - sj * st) / denom : 0.0;
            const double span = js.back() - js.front();
            if (fitted > 0.0 && span > 0.0) {
                const double tol = kBeatTolerance / span;
                out.bpm = snapBpm(60.0 / (fitted + tol), 60.0 / fitted, 60.0 / (fitted - tol));
                const double length = 60.0 / out.bpm;
                std::vector<double> intercepts;
                for (size_t i = 0; i < js.size(); i++) intercepts.push_back(ts[i] - js[i] * length);
                const double intercept = median(intercepts);
                out.anchorSeconds = intercept - std::floor(intercept / length) * length;
            }
        }
    }
    return out;
}

Phases barAndPhrasePhase(const BeatGrid &grid, const BandEnergies &bands, const std::vector<float> &envelope,
                         double fps, double firstFrameSeconds, double durationSeconds, int barPhase) {
    Phases out;
    const bool fixedBars = barPhase >= 0 && barPhase < kBeatsPerBar;
    if (fixedBars) out.barPhase = barPhase;
    const double beat = grid.beatSeconds();
    if (!(beat > 0.0) || !(fps > 0.0) || bands[0].empty()) return out;
    const long beats = static_cast<long>(std::floor((durationSeconds - grid.anchorSeconds) / beat));
    constexpr long kCycle = kBeatsPerBar * 8;          // a 32-beat phrase
    constexpr long kHalfKernel = 4 * kBeatsPerBar;     // 4 bars each side
    if (beats < 2 * kCycle) return out;

    // Per beat: low / mid / high band energy and onset strength
    constexpr int kFeatures = 4;
    const size_t frames = std::min(envelope.size(), bands[0].size());
    auto frameAt = [&](double t) {
        const double k = std::ceil((t - kOnsetCorrection - firstFrameSeconds) * fps);
        return static_cast<size_t>(std::clamp(k, 0.0, static_cast<double>(frames)));
    };
    std::vector<std::array<double, kFeatures>> v(static_cast<size_t>(beats));
    for (long b = 0; b < beats; b++) {
        const size_t k0 = frameAt(grid.beatTime(b)), k1 = frameAt(grid.beatTime(b + 1));
        std::array<double, kFeatures> sum{};
        for (size_t k = k0; k < k1; k++) {
            for (int f = 0; f < 3; f++) sum[f] += bands[f][k];
            sum[3] += envelope[k];
        }
        for (int f = 0; f < kFeatures; f++) v[static_cast<size_t>(b)][f] = k1 > k0 ? sum[f] / (k1 - k0) : 0.0;
    }
    // In log, over a floor relative to each one's typical level (silence
    // stays finite), in units of 6 dB so a threshold means the same for all
    const double kUnit = std::log(4.0);   // power x4 = 6 dB
    for (int f = 0; f < kFeatures; f++) {
        std::vector<double> level;
        for (const auto &x : v) level.push_back(x[f]);
        const double typical = median(level);
        const double floorLevel = typical > 0.0 ? 1e-3 * typical : 1e-12;
        for (auto &x : v) x[f] = std::log(floorLevel + x[f]) / kUnit;
    }

    // Novelty at a beat: Foote's checkerboard kernel, Gaussian-tapered, over
    // the distances between the beats `half` either side, as the mean
    // distance across the beat minus the mean within each side. A clean step
    // of d units in one feature scores d / 2
    auto distance = [&](long a, long b) {
        double d = 0.0;
        for (int f = 0; f < kFeatures; f++) {
            const double x = v[static_cast<size_t>(a)][f] - v[static_cast<size_t>(b)][f];
            d += x * x;
        }
        return std::sqrt(d);
    };
    auto noveltyAt = [&](long b, long half) {
        double n = 0.0, weights = 0.0;
        for (long x = -half; x < half; x++) {
            const double tx = (x + 0.5) / (0.5 * half);
            for (long y = -half; y < half; y++) {
                const double ty = (y + 0.5) / (0.5 * half);
                const double w = std::exp(-0.5 * (tx * tx + ty * ty));
                n += ((x < 0) == (y < 0) ? -w : w) * distance(b + x, b + y);
                weights += w;
            }
        }
        return std::max(0.0, 2.0 * n / weights);
    };
    std::vector<double> novelty(static_cast<size_t>(beats), 0.0);
    for (long b = kHalfKernel; b + kHalfKernel <= beats; b++) novelty[static_cast<size_t>(b)] = noveltyAt(b, kHalfKernel);

    // The clear changes vote for their place in the 32-beat cycle: local
    // peaks of at least kMinChange and over the mean plus one spread. Sections
    // that build up or sweep in put the 4-bar peak a few beats off, so each is
    // pinned to the beat where a 1-bar kernel peaks within half a bar of it
    constexpr double kMinChange = 0.25;   // a 3 dB step
    constexpr long kFineHalf = kBeatsPerBar, kSearch = kBeatsPerBar / 2;
    double mean = 0.0, var = 0.0;
    for (double n : novelty) mean += n;
    mean /= static_cast<double>(beats);
    for (double n : novelty) var += (n - mean) * (n - mean);
    const double threshold = std::max(kMinChange, mean + std::sqrt(var / static_cast<double>(beats)));
    std::vector<double> votes(kCycle, 0.0);
    for (long b = 1; b + 1 < beats; b++) {
        const double n = novelty[static_cast<size_t>(b)];
        if (!(n > threshold && n >= novelty[static_cast<size_t>(b - 1)] && n > novelty[static_cast<size_t>(b + 1)])) continue;
        long at = b;
        double best = -1.0;
        for (long c = std::max(kFineHalf, b - kSearch); c <= std::min(beats - kFineHalf, b + kSearch); c++) {
            const double fine = noveltyAt(c, kFineHalf);
            if (fine > best) {
                best = fine;
                at = c;
            }
        }
        votes[static_cast<size_t>(at % kCycle)] += n;
    }

    // Where phrases start: the centre of the strongest cluster of changes.
    // Fills in the bar before, drop-outs a beat early and parts entering a bar
    // late scatter real section changes over a few beats either side, so the
    // votes are smoothed over a bar each way. A phrase starts on a bar, so
    // the bar phase follows. Confidence: how much the best position beats the
    // best one at least 2 bars away (another cluster, e.g. 4-bar phrases)
    auto circular = [](long a, long b) {
        const long d = std::labs(a - b) % kCycle;
        return std::min(d, kCycle - d);
    };
    std::vector<double> score(kCycle, 0.0);
    for (long c = 0; c < kCycle; c++) {
        for (long o = 0; o < kCycle; o++) {
            const long d = circular(o, c);
            if (d <= kBeatsPerBar) score[static_cast<size_t>(c)] += votes[static_cast<size_t>(o)] * (1.0 - d / (kBeatsPerBar + 1.0));
        }
    }
    // With the bar phase known (downbeats), only starts on it compete
    auto allowed = [&](long c) { return !fixedBars || c % kBeatsPerBar == barPhase; };
    long start = -1;
    for (long c = 0; c < kCycle; c++) {
        if (allowed(c) && (start < 0 || score[static_cast<size_t>(c)] > score[static_cast<size_t>(start)])) start = c;
    }
    double rival = 0.0;
    for (long c = 0; c < kCycle; c++) {
        if (allowed(c) && circular(c, start) >= 2 * kBeatsPerBar) rival = std::max(rival, score[static_cast<size_t>(c)]);
    }
    const double best = score[static_cast<size_t>(start)];
    const double confidence = best > 1e-12 ? (best - rival) / best : 0.0;
    if (!fixedBars) out.barConfidence = confidence;
    out.phraseConfidence = confidence;
    if (confidence < jl_phrase_min_confidence) return out;
    out.barPhase = static_cast<int>(start % kBeatsPerBar);
    out.phraseBars = static_cast<int>(start / kBeatsPerBar);
    return out;
}

BarVote barPhaseFromDownbeats(const BeatGrid &grid, const std::vector<double> &downbeats) {
    BarVote out;
    const double beat = grid.beatSeconds();
    if (!(beat > 0.0)) return out;
    std::array<double, kBeatsPerBar> votes{};
    size_t onGrid = 0;
    for (double d : downbeats) {
        const long j = std::lround((d - grid.anchorSeconds) / beat);
        if (std::fabs(d - grid.beatTime(j)) > kBeatTolerance) continue;   // off the master grid: says nothing about its bars
        votes[static_cast<size_t>(((j % kBeatsPerBar) + kBeatsPerBar) % kBeatsPerBar)] += 1.0;
        onGrid++;
    }
    if (onGrid < kMinDownbeatVotes) return out;
    const size_t best = static_cast<size_t>(std::max_element(votes.begin(), votes.end()) - votes.begin());
    double second = 0.0;
    for (size_t i = 0; i < votes.size(); i++) {
        if (i != best) second = std::max(second, votes[i]);
    }
    out.confidence = (votes[best] - second) / votes[best];
    if (out.confidence >= jl_phrase_min_confidence) out.phase = static_cast<int>(best);
    return out;
}

} // namespace detail

namespace {

// What a bar's statistics are measured from, before the re-anchor flags:
// each bar's offsets (seconds) of what sits at its grid beats, and the
// statistics so far
struct BarEvidence {
    std::vector<BarStat> bars;
    std::vector<std::vector<double>> offsets;
};

size_t barCountOf(const BeatGrid &grid, double durationSeconds) {
    const double beat = grid.beatSeconds(), barsFrom = grid.beatTime(grid.firstBarBeat());
    if (!(beat > 0.0) || !(durationSeconds > barsFrom)) return 0;
    return static_cast<size_t>(std::ceil((durationSeconds - barsFrom) / (beat * kBeatsPerBar)));
}

// The offsets' median and matched beats into the statistics
void summariseBars(BarEvidence &e, const std::vector<uint8_t> &matchedMask) {
    for (size_t i = 0; i < e.bars.size(); i++) {
        const double ms = std::clamp(std::round(median(e.offsets[i]) * 1000.0), -127.0, 127.0);
        e.bars[i].offset_ms = static_cast<int8_t>(ms);
        e.bars[i].matched = static_cast<uint8_t>(__builtin_popcount(matchedMask[i]));
    }
}

struct Onset {
    double offset = 0.0;            // seconds from the grid beat
    double strength = 0.0;          // the strongest envelope value around it
    bool found = false;
};

// The onset peak nearest grid beat j within half a beat, among those at
// least half as strong as the strongest there, to sub-frame precision
Onset onsetNear(const BeatGrid &grid, const std::vector<float> &envelope, double fps, double firstFrameSeconds,
                long j) {
    Onset out;
    const long frames = static_cast<long>(envelope.size());
    const double halfBeat = 0.5 * grid.beatSeconds() * fps;
    const double centre = (grid.beatTime(j) - kOnsetCorrection - firstFrameSeconds) * fps;
    const long lo = std::max(1L, static_cast<long>(std::ceil(centre - halfBeat)));
    const long hi = std::min(frames - 2, static_cast<long>(std::floor(centre + halfBeat)));
    if (lo > hi) return out;
    float strongest = 0.0f;
    for (long k = lo; k <= hi; k++) strongest = std::max(strongest, envelope[static_cast<size_t>(k)]);
    if (!(strongest > 0.0f)) return out;
    double nearest = halfBeat + 1.0;
    for (long k = lo; k <= hi; k++) {
        const float e = envelope[static_cast<size_t>(k)];
        if (e < 0.5f * strongest || e < envelope[static_cast<size_t>(k - 1)] || e < envelope[static_cast<size_t>(k + 1)]) continue;
        const double left = envelope[static_cast<size_t>(k - 1)], right = envelope[static_cast<size_t>(k + 1)];
        const double denom = left - 2.0 * e + right;
        const double peak = k + (denom < 0.0 ? std::clamp(0.5 * (left - right) / denom, -0.5, 0.5) : 0.0);
        if (std::fabs(peak - centre) < std::fabs(nearest)) nearest = peak - centre;
    }
    if (std::fabs(nearest) > halfBeat) return out;
    out.offset = nearest / fps;
    out.strength = strongest;
    out.found = true;
    return out;
}

// From the audio: the onsets at each grid beat, the bar's onset energy
BarEvidence onsetEvidence(const BeatGrid &grid, const std::vector<float> &envelope, double fps,
                          double firstFrameSeconds, double durationSeconds) {
    BarEvidence e;
    const double beat = grid.beatSeconds(), barLength = beat * kBeatsPerBar;
    const long first = grid.firstBarBeat();
    const double barsFrom = grid.beatTime(first);
    const size_t barCount = barCountOf(grid, durationSeconds);
    if (barCount == 0) return e;
    e.bars.resize(barCount);
    e.offsets.resize(barCount);
    std::vector<BarStat> &bars = e.bars;
    std::vector<std::vector<double>> &offsets = e.offsets;
    // Offsets and matches from the audio at each grid beat: the onset peak
    // nearest the beat within half a beat, among those at least half as
    // strong as the strongest there. The tracker's beats can lock onto
    // another layer where the kick drops out (a rolling bassline a quarter
    // beat off) while the music stays on the grid; its onsets show that.
    std::vector<uint8_t> matchedMask(barCount, 0);
    std::vector<int> offbeats(barCount, 0);
    std::vector<double> beatStrength;
    const long lastBeat = first + static_cast<long>(barCount) * kBeatsPerBar;
    std::vector<Onset> onsets;
    for (long j = first; j < lastBeat; j++) {
        onsets.push_back(onsetNear(grid, envelope, fps, firstFrameSeconds, j));
        if (onsets.back().found) beatStrength.push_back(onsets.back().strength);
    }
    // Beats in near-silence say nothing about the grid
    const double quietBeat = kNoPulseLevel * median(beatStrength);
    for (long j = first; j < lastBeat; j++) {
        const Onset &o = onsets[static_cast<size_t>(j - first)];
        if (!o.found || o.strength < quietBeat) continue;
        const size_t bar = static_cast<size_t>(j - first) / kBeatsPerBar;
        offsets[bar].push_back(o.offset);
        if (std::fabs(o.offset) <= kBeatTolerance) {
            matchedMask[bar] |= static_cast<uint8_t>(1u << ((j - first) % kBeatsPerBar));
        } else if (std::fabs(std::fabs(o.offset) - 0.5 * beat) <= kBeatTolerance) {
            offbeats[bar]++;
        }
    }
    summariseBars(e, matchedMask);
    for (size_t i = 0; i < barCount; i++) {
        // Onsets only on the off-beats: nothing on the beats to judge by
        if (bars[i].matched <= 1 && offbeats[i] >= 3) bars[i].flags |= jl_bar_offbeat;
    }

    // Pulse: mean envelope over the bar against the median bar. (Tried and
    // dropped: the onsets' autocorrelation one beat apart. It did not catch
    // busy beatless textures and turned reverb-washed kicks into no pulse;
    // see docs/BEATGRID-VALIDATION.md.)
    std::vector<double> means(barCount, 0.0);
    for (size_t i = 0; i < barCount; i++) {
        const double t0 = barsFrom + i * barLength, t1 = t0 + barLength;
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
    return e;
}

// A network source's beats, each moved to the onset peak within
// kOnsetSearch of it (among those at least half as strong as the strongest
// there) when that peak is strong enough to measure and the network is sure
// of the beat. Other beats keep the network's time and are not measured.
struct RefinedBeats {
    std::vector<double> times;
    std::vector<bool> measured;
    std::vector<float> confidence;  // the network's, per beat; empty: all sure
};
RefinedBeats refineOnOnsets(const RawBeats &raw, const std::vector<float> &envelope, double fps,
                            double firstFrameSeconds) {
    const std::vector<double> &beats = raw.beats;
    RefinedBeats out;
    out.times = beats;
    out.measured.assign(beats.size(), false);
    if (raw.confidence.size() == beats.size()) out.confidence = raw.confidence;
    const long frames = static_cast<long>(envelope.size());
    const double reach = kOnsetSearch * fps;
    std::vector<double> peakTime(beats.size(), 0.0), peakStrength(beats.size(), 0.0);
    std::vector<double> strengths;
    for (size_t i = 0; i < beats.size(); i++) {
        const double centre = (beats[i] - kOnsetCorrection - firstFrameSeconds) * fps;
        const long lo = std::max(1L, static_cast<long>(std::ceil(centre - reach)));
        const long hi = std::min(frames - 2, static_cast<long>(std::floor(centre + reach)));
        if (lo > hi) continue;
        float strongest = 0.0f;
        for (long k = lo; k <= hi; k++) strongest = std::max(strongest, envelope[static_cast<size_t>(k)]);
        if (!(strongest > 0.0f)) continue;
        double nearest = reach + 1.0;
        for (long k = lo; k <= hi; k++) {
            const float e = envelope[static_cast<size_t>(k)];
            if (e < 0.5f * strongest || e < envelope[static_cast<size_t>(k - 1)] || e < envelope[static_cast<size_t>(k + 1)]) continue;
            const double left = envelope[static_cast<size_t>(k - 1)], right = envelope[static_cast<size_t>(k + 1)];
            const double denom = left - 2.0 * e + right;
            const double peak = k + (denom < 0.0 ? std::clamp(0.5 * (left - right) / denom, -0.5, 0.5) : 0.0);
            if (std::fabs(peak - centre) < std::fabs(nearest)) nearest = peak - centre;
        }
        if (std::fabs(nearest) > reach) continue;
        peakTime[i] = beats[i] + nearest / fps;
        peakStrength[i] = strongest;
        strengths.push_back(strongest);
    }
    const double quiet = kNoPulseLevel * median(strengths);
    auto sure = [&](size_t i) { return raw.confidence.size() != beats.size() || raw.confidence[i] >= kSureBeat; };
    for (size_t i = 0; i < beats.size(); i++) {
        if (peakStrength[i] > 0.0 && peakStrength[i] >= quiet && sure(i)) {
            out.times[i] = peakTime[i];
            out.measured[i] = true;
        }
    }
    return out;
}

// From a network source's refined beats: offsets and matches from the
// measured beat nearest each grid beat; pulse the share of measured beats,
// none under two (no beat heard, or nothing to measure it by)
BarEvidence measuredEvidence(const BeatGrid &grid, const RefinedBeats &refined, double durationSeconds) {
    BarEvidence e;
    const double beat = grid.beatSeconds();
    const long first = grid.firstBarBeat();
    const size_t barCount = barCountOf(grid, durationSeconds);
    if (barCount == 0) return e;
    e.bars.resize(barCount);
    e.offsets.resize(barCount);
    std::vector<uint8_t> matchedMask(barCount, 0);
    std::vector<int> subdivisions(barCount, 0);
    const double halfBeat = 0.5 * beat;
    const std::vector<double> &times = refined.times;
    for (long j = first; j < first + static_cast<long>(barCount) * kBeatsPerBar; j++) {
        const double t = grid.beatTime(j);
        const size_t bar = static_cast<size_t>(j - first) / kBeatsPerBar;
        auto it = std::lower_bound(times.begin(), times.end(), t);
        size_t best = times.size();
        if (it != times.end()) best = static_cast<size_t>(it - times.begin());
        if (it != times.begin() && (best == times.size() || t - *(it - 1) < times[best] - t)) best = static_cast<size_t>(it - times.begin()) - 1;
        if (best == times.size() || !refined.measured[best] || std::fabs(times[best] - t) > halfBeat) continue;
        const double offset = times[best] - t;
        // Off the grid beat, only a beat the network is very sure of says the
        // grid is wrong there
        if (std::fabs(offset) > kBeatTolerance && !refined.confidence.empty() &&
            refined.confidence[best] < kSureOffGrid) {
            continue;
        }
        e.offsets[bar].push_back(offset);
        if (std::fabs(offset) <= kBeatTolerance) {
            matchedMask[bar] |= static_cast<uint8_t>(1u << ((j - first) % kBeatsPerBar));
        } else {
            // On a quarter, half or three-quarter beat: still on the grid's
            // subdivisions (the kick out, the network following a rolling
            // bassline a 16th late)
            const double quarter = 0.25 * beat;
            const double q = std::fabs(offset) / quarter;
            if (std::fabs(q - std::round(q)) * quarter <= kBeatTolerance) subdivisions[bar]++;
        }
    }
    summariseBars(e, matchedMask);
    for (size_t i = 0; i < barCount; i++) {
        const int measured = static_cast<int>(e.offsets[i].size());
        e.bars[i].pulse = static_cast<uint8_t>(measured >= 2 ? kPulseUnit * measured / kBeatsPerBar : 0);
        // Beats only between the grid beats: nothing on the beats to judge by
        if (e.bars[i].matched <= 1 && subdivisions[i] >= 2) e.bars[i].flags |= jl_bar_offbeat;
    }
    return e;
}

// Where one grid gives way to another, into the statistics
void flagRegionStarts(const BeatGrid &grid, BarEvidence &e) {
    std::vector<BarStat> &bars = e.bars;
    const std::vector<std::vector<double>> &offsets = e.offsets;
    const size_t barCount = bars.size();
    if (barCount == 0) return;
    const double beat = grid.beatSeconds();
    const long first = grid.firstBarBeat();
    // Where one grid gives way to another: a stable region whose tempo steps
    // from the previous stable region's, or whose first beat is off that
    // region's grid - a phase jump, confirmed by the audio: the onsets of the
    // bars after it sit apart from those before it. The tracker also jumps
    // when it moves to another layer (an off-beat bassline) while the music
    // stays put. Splits within one grid (jitter) and gradual ramps meet on a
    // shared beat with small steps and are not flagged.
    auto evidence = [&](size_t i) {
        return !offsets[i].empty() && !(bars[i].flags & jl_bar_offbeat) && bars[i].pulse >= kNoPulseLevel * kPulseUnit;
    };
    auto onsetOffset = [&](size_t from, size_t to) {   // median over up to 8 bars with evidence, [from, to)
        std::vector<double> v;
        for (size_t i = from; i < to && v.size() < 8; i++) {
            if (evidence(i)) v.push_back(bars[i].offset_ms);
        }
        return v.empty() ? std::nan("") : median(v);
    };
    auto onsetOffsetBefore = [&](size_t to) {
        std::vector<double> v;
        for (size_t i = to; i-- > 0 && v.size() < 8;) {
            if (evidence(i)) v.push_back(bars[i].offset_ms);
        }
        return v.empty() ? std::nan("") : median(v);
    };
    const BeatRegion *previous = nullptr;
    for (const BeatRegion &g : grid.regions) {
        if (!g.stable() || g.unsure) continue;
        if (previous) {
            const long j = std::max(first, std::lround((g.startSeconds - grid.anchorSeconds) / beat));
            const size_t bar = std::min(barCount - 1, static_cast<size_t>(j - first) / kBeatsPerBar);
            const double gap = g.startSeconds - previous->endSeconds();
            const double phase = gap - std::round(gap / previous->beatSeconds) * previous->beatSeconds;
            const bool step = std::fabs(g.beatSeconds - previous->beatSeconds) > kTempoStep * previous->beatSeconds;
            const double after = onsetOffset(bar, barCount), before = onsetOffsetBefore(bar);
            const bool moved = !std::isnan(after) && !std::isnan(before) && std::fabs(after - before) > kBeatTolerance * 1000.0;
            if (step || (std::fabs(phase) > kBeatTolerance && moved)) bars[bar].flags |= kBarRegionStart;
        }
        previous = &g;
    }
}

// Regions where many beats carry almost no onset energy (the tracker running
// through a silence or a beatless stretch, or re-syncing as it ends) neither
// anchor the grid nor mark where a new one begins. With a network source,
// also flags regions where most beats are not measured (see kUnsureShare).
void markQuietRegions(std::vector<BeatRegion> &regions, const std::vector<double> &beats,
                      const std::vector<float> &envelope, double fps, double firstFrameSeconds,
                      const std::vector<bool> *measured = nullptr) {
    if (envelope.empty() || beats.empty()) return;
    const bool byMeasure = measured && measured->size() == beats.size();
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
        size_t count = 0, weak = 0, unmeasured = 0;
        const double end = g.endSeconds() + 1e-6;
        while (next < beats.size() && beats[next] < g.startSeconds - 1e-6) next++;
        for (size_t k = next; k < beats.size() && beats[k] <= end; k++) {
            count++;
            weak += all[k] < kNoPulseLevel * typical;
            unmeasured += byMeasure && !(*measured)[k];
        }
        const double n = static_cast<double>(count);
        g.quiet = count > 0 && static_cast<double>(weak) > kQuietShare * n;
        g.unsure = count > 0 && static_cast<double>(unmeasured) > kUnsureShare * n;
    }
}

} // namespace

BeatGrid buildBeatGrid(const RawBeats &raw, const std::vector<float> &envelope, double fps,
                       double firstFrameSeconds, double durationSeconds, const BandEnergies *bands) {
    BeatGrid grid;
    grid.source = raw.source;
    const bool network = raw.source == BeatSource::BeatThis;
    RefinedBeats refined;
    if (network) refined = refineOnOnsets(raw, envelope, fps, firstFrameSeconds);
    const std::vector<double> &beats = network ? refined.times : raw.beats;
    grid.beats = beats;
    grid.regions = detail::constantRegions(beats);
    markQuietRegions(grid.regions, beats, envelope, fps, firstFrameSeconds, network ? &refined.measured : nullptr);
    const detail::MasterGrid master = detail::masterGrid(grid.regions, beats);
    if (!master.valid) return grid;
    grid.bpm = master.bpm;
    grid.anchorSeconds = master.anchorSeconds;
    // Bar phase from the source's downbeats when it has them; the section
    // changes then only pick which bar starts a phrase
    detail::BarVote vote;
    if (!raw.downbeats.empty()) vote = detail::barPhaseFromDownbeats(grid, raw.downbeats);
    if (vote.phase >= 0) {
        grid.barPhase = static_cast<int8_t>(vote.phase);
        grid.barConfidence = static_cast<float>(vote.confidence);
    }
    if (bands) {
        const detail::Phases phases =
            detail::barAndPhrasePhase(grid, *bands, envelope, fps, firstFrameSeconds, durationSeconds, vote.phase);
        grid.barPhase = static_cast<int8_t>(phases.barPhase);
        if (vote.phase < 0) grid.barConfidence = static_cast<float>(phases.barConfidence);
        grid.phrasePhaseBars = static_cast<int8_t>(phases.phraseBars);
        grid.phraseConfidence = static_cast<float>(phases.phraseConfidence);
    }
    BarEvidence evidence = network ? measuredEvidence(grid, refined, durationSeconds)
                                   : onsetEvidence(grid, envelope, fps, firstFrameSeconds, durationSeconds);
    flagRegionStarts(grid, evidence);
    grid.bars = std::move(evidence.bars);
    grid.valid = !grid.bars.empty();
    return grid;
}

BeatGrid analyseBeatGrid(const std::vector<float> &envelope, const BandEnergies &bands, double fps,
                         double firstFrameSeconds, double durationSeconds, const BeatGridHints &hints) {
    const TempoResult tempo = estimateTempo(envelope, fps);
    if (!tempo.valid) return BeatGrid();
    const double bpmEstimate = detail::applyHints(tempo.bpm, hints);

    RawBeats raw;
    for (double frame : detail::trackBeats(envelope, fps, bpmEstimate)) {
        raw.beats.push_back(firstFrameSeconds + frame / fps + kOnsetCorrection);
    }
    BeatGrid grid = buildBeatGrid(raw, envelope, fps, firstFrameSeconds, durationSeconds, &bands);
    grid.tempoStrength = static_cast<float>(tempo.strength);
    grid.uncertain = tempo.strength < kUncertainStrength;
    return grid;
}

BeatGrid analyseNetworkBeatGrid(const RawBeats &network, const std::vector<float> &envelope, const BandEnergies &bands,
                                double fps, double firstFrameSeconds, double durationSeconds) {
    RawBeats raw = network;
    raw.source = BeatSource::BeatThis;
    BeatGrid grid = buildBeatGrid(raw, envelope, fps, firstFrameSeconds, durationSeconds, &bands);
    if (!grid.valid) return grid;
    // How much of the track the grid is heard on: grid beats with a sure,
    // measured network beat within the tolerance
    size_t matched = 0;
    for (const BarStat &b : grid.bars) matched += b.matched;
    const double strength = static_cast<double>(matched) / static_cast<double>(grid.bars.size() * kBeatsPerBar);
    grid.tempoStrength = static_cast<float>(strength);
    grid.uncertain = strength < kUncertainStrength;
    return grid;
}

TempoResult networkTempo(const BeatGrid &grid) {
    TempoResult result;
    if (!grid.valid || grid.source != BeatSource::BeatThis) return result;
    result.valid = true;
    result.bpm = grid.bpm;
    result.strength = grid.tempoStrength;
    return result;
}

} // namespace bpm
