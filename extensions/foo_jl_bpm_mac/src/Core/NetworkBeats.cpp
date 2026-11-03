//
//  NetworkBeats.cpp
//  foo_jl_bpm_mac
//

#include "NetworkBeats.h"

#include <algorithm>
#include <cmath>

namespace bpm {

std::vector<long> networkChunkStarts(long frames) {
    std::vector<long> starts;
    if (frames <= 0) return starts;
    const long step = kNetworkChunk - 2 * kNetworkBorder;
    for (long s = -kNetworkBorder; s < frames - kNetworkBorder; s += step) starts.push_back(s);
    // The last chunk ends on the piece's end rather than running short
    if (frames > step) starts.back() = frames - (kNetworkChunk - kNetworkBorder);
    return starts;
}

long chunkInput(const std::vector<float> &spectrogram, long frames, long bins, long start, std::vector<float> &out) {
    const long from = std::max(start, 0L), to = std::min(start + kNetworkChunk, frames);
    const long left = std::max(0L, -start);
    const long right = std::max(0L, std::min(kNetworkBorder, start + kNetworkChunk - frames));
    const long rows = left + std::max(0L, to - from) + right;
    out.assign(static_cast<size_t>(rows * bins), 0.0f);
    for (long r = from; r < to; r++) {
        std::copy_n(spectrogram.begin() + r * bins, bins, out.begin() + (left + r - from) * bins);
    }
    return rows;
}

void mergeChunk(const std::vector<float> &chunk, long rows, long start, std::vector<float> &piece,
                std::vector<bool> &filled) {
    const long frames = static_cast<long>(piece.size());
    for (long i = kNetworkBorder; i < rows - kNetworkBorder; i++) {
        const long f = start + i;
        if (f < 0 || f >= frames || filled[static_cast<size_t>(f)]) continue;
        piece[static_cast<size_t>(f)] = chunk[static_cast<size_t>(i)];
        filled[static_cast<size_t>(f)] = true;
    }
}

NetworkChunker::NetworkChunker(long bins, Runner run) : bins_(bins), run_(std::move(run)) {}

bool NetworkChunker::runChunk(long start) {
    // The rows upstream gives this chunk: zero rows before the piece, the
    // piece's frames, up to the border's worth of zero rows past its end
    const long end = received_;
    const long from = std::max(start, 0L), to = std::min(start + kNetworkChunk, end);
    const long left = std::max(0L, -start);
    const long right = std::max(0L, std::min(kNetworkBorder, start + kNetworkChunk - end));
    const long rows = left + std::max(0L, to - from) + right;
    input_.assign(static_cast<size_t>(rows * bins_), 0.0f);
    for (long r = from; r < to; r++) {
        std::copy_n(stored_.begin() + (r - base_) * bins_, bins_, input_.begin() + (left + r - from) * bins_);
    }
    chunkBeat_.assign(static_cast<size_t>(rows), 0.0f);
    chunkDownbeat_.assign(static_cast<size_t>(rows), 0.0f);
    if (!run_(input_.data(), rows, chunkBeat_.data(), chunkDownbeat_.data())) {
        failed_ = true;
        return false;
    }
    beat_.resize(static_cast<size_t>(end), -1000.0f);
    downbeat_.resize(static_cast<size_t>(end), -1000.0f);
    filled_.resize(static_cast<size_t>(end), false);
    std::vector<bool> filledDown = filled_;
    mergeChunk(chunkBeat_, rows, start, beat_, filled_);
    mergeChunk(chunkDownbeat_, rows, start, downbeat_, filledDown);
    lastRun_ = start;
    return true;
}

bool NetworkChunker::add(const float *frames, long count) {
    if (failed_ || count <= 0) return !failed_;
    stored_.insert(stored_.end(), frames, frames + count * bins_);
    received_ += count;
    // A chunk whose frames are all in is never the last one upstream would
    // move back to the piece's end: the next start is still inside the piece
    while (nextStart_ + kNetworkChunk <= received_) {
        if (!runChunk(nextStart_)) return false;
        nextStart_ += kNetworkChunk - 2 * kNetworkBorder;
    }
    // Later chunks start at nextStart_, or for the last one at most a chunk
    // before the end
    const long keepFrom = std::max(0L, std::min(nextStart_, received_ - kNetworkChunk));
    if (keepFrom > base_) {
        stored_.erase(stored_.begin(), stored_.begin() + (keepFrom - base_) * bins_);
        base_ = keepFrom;
    }
    return true;
}

bool NetworkChunker::finish() {
    if (failed_) return false;
    for (long start : networkChunkStarts(received_)) {
        if (start > lastRun_ && !runChunk(start)) return false;
    }
    return true;
}

std::vector<double> pickPeaks(const std::vector<float> &logits) {
    constexpr long kReach = 3;   // +-70 ms at 50 fps
    const long n = static_cast<long>(logits.size());
    std::vector<long> frames;
    for (long k = 0; k < n; k++) {
        const float v = logits[static_cast<size_t>(k)];
        if (!(v > 0.0f)) continue;
        bool peak = true;
        for (long j = std::max(0L, k - kReach); j <= std::min(n - 1, k + kReach) && peak; j++) {
            peak = logits[static_cast<size_t>(j)] <= v;
        }
        if (peak) frames.push_back(k);
    }
    // Adjacent maxima (equal logits) merge as upstream's deduplicate_peaks
    // does: a running mean, the next frame compared against that mean
    std::vector<double> out;
    auto finish = [&](double mean, int count) {
        if (count == 1) {
            const long k = static_cast<long>(mean);
            if (k > 0 && k + 1 < n) {
                const double l = logits[static_cast<size_t>(k - 1)], c = logits[static_cast<size_t>(k)],
                             r = logits[static_cast<size_t>(k + 1)];
                const double denom = l - 2.0 * c + r;
                if (denom < 0.0) mean += std::clamp(0.5 * (l - r) / denom, -0.5, 0.5);
            }
        }
        out.push_back(mean);
    };
    if (frames.empty()) return out;
    double mean = static_cast<double>(frames[0]);
    int count = 1;
    for (size_t i = 1; i < frames.size(); i++) {
        const double f = static_cast<double>(frames[i]);
        if (f - mean <= 1.0) {
            count++;
            mean += (f - mean) / count;
        } else {
            finish(mean, count);
            mean = f;
            count = 1;
        }
    }
    finish(mean, count);
    return out;
}

RawBeats networkBeats(const std::vector<float> &beatLogits, const std::vector<float> &downbeatLogits) {
    RawBeats raw;
    raw.source = BeatSource::BeatThis;
    for (double f : pickPeaks(beatLogits)) raw.beats.push_back(f / kNetworkFps);
    if (!raw.beats.empty()) {
        for (double f : pickPeaks(downbeatLogits)) {
            const double t = f / kNetworkFps;
            auto it = std::lower_bound(raw.beats.begin(), raw.beats.end(), t);
            double nearest = it == raw.beats.end() ? raw.beats.back() : *it;
            if (it != raw.beats.begin() && (it == raw.beats.end() || t - *(it - 1) <= *it - t)) nearest = *(it - 1);
            if (raw.downbeats.empty() || raw.downbeats.back() != nearest) raw.downbeats.push_back(nearest);
        }
    }
    // How sure the network is of each beat: its probability at the peak
    const long n = static_cast<long>(beatLogits.size());
    for (double t : raw.beats) {
        const long k = std::lround(t * kNetworkFps);
        float best = -1e9f;
        for (long i = std::max(0L, k - 1); i <= std::min(n - 1, k + 1); i++) best = std::max(best, beatLogits[static_cast<size_t>(i)]);
        raw.confidence.push_back(1.0f / (1.0f + std::exp(-best)));
    }
    return raw;
}

} // namespace bpm
