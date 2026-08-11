//
//  PeakBinner.h
//  foo_wave_seekbar_mac
//
//  Folds decoded audio frames into fixed-count min/max/RMS buckets.
//
//  Samples are assigned to buckets by absolute position in the track, so the
//  track can be decoded as independent segments - in any order, on any
//  thread - and give the same result as one sequential pass. The scanner owns
//  the decoders, seeking and threading; this header owns the bucket
//  boundaries and the peak math, so both are unit-tested without a decoder or
//  the foobar2000 SDK. addInterleaved is a template over the sample type to
//  work whether audio_sample is float or double.
//

#pragma once

#include "WaveformData.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace waveseek {

// Source samples in the declared track length. The length is only an
// estimate, and a non-finite or non-positive one must not reach the integer
// cast; the clamp keeps bucket * total in BucketLayout from overflowing.
inline uint64_t declaredSampleCount(double duration, uint32_t sampleRate) {
    double total = duration * static_cast<double>(sampleRate);
    if (!std::isfinite(total) || total < 1.0) {
        return 1;
    }
    constexpr double kMax = static_cast<double>(std::numeric_limits<uint64_t>::max() / WaveformData::BUCKET_COUNT);
    return total >= kMax ? static_cast<uint64_t>(kMax) : static_cast<uint64_t>(total);
}

// Bucket b covers samples [b * total / count, (b + 1) * total / count), so
// bucket sizes differ by at most one and none of the track is dropped. The
// last bucket is open-ended: it takes any samples past the declared length.
class BucketLayout {
public:
    BucketLayout(uint64_t totalSamples, size_t bucketCount)
        : m_total(std::max<uint64_t>(totalSamples, 1))
        , m_count(std::max<size_t>(bucketCount, 1)) {}

    size_t count() const { return m_count; }

    uint64_t start(size_t bucket) const {
        return static_cast<uint64_t>(bucket) * m_total / m_count;
    }

    uint64_t end(size_t bucket) const {
        return bucket + 1 >= m_count
            ? std::numeric_limits<uint64_t>::max()
            : start(bucket + 1);
    }

private:
    uint64_t m_total;
    size_t m_count;
};

namespace detail {

// Min, max and sum of squares over n strided samples, computed by vDSP in the
// sample type's own precision and widened afterwards.
inline void runStats(const float* src, vDSP_Stride stride, vDSP_Length n,
                     double& mn, double& mx, double& sumSq) {
    float a, b, c;
    vDSP_minv(src, stride, &a, n);
    vDSP_maxv(src, stride, &b, n);
    vDSP_svesq(src, stride, &c, n);
    mn = a;
    mx = b;
    sumSq = c;
}

inline void runStats(const double* src, vDSP_Stride stride, vDSP_Length n,
                     double& mn, double& mx, double& sumSq) {
    vDSP_minvD(src, stride, &mn, n);
    vDSP_maxvD(src, stride, &mx, n);
    vDSP_svesqD(src, stride, &sumSq, n);
}

} // namespace detail

class PeakBinner {
    struct Accumulator {
        double min[2] = {std::numeric_limits<double>::infinity(), std::numeric_limits<double>::infinity()};
        double max[2] = {-std::numeric_limits<double>::infinity(), -std::numeric_limits<double>::infinity()};
        double sumSq[2] = {0.0, 0.0};
        uint64_t count = 0;
    };

public:
    // One contiguous run of buckets, fed in decode order starting at
    // startSample(). Segments over disjoint bucket ranges write disjoint
    // accumulators, so they may be filled concurrently from different threads.
    class Segment {
    public:
        // Where the segment's decoder must seek to before feeding it
        uint64_t startSample() const { return m_start; }

        // Every sample of the segment has arrived. A segment ending at the
        // last bucket never reports done; it runs until the decoder ends.
        bool done() const { return m_pos >= m_end; }

        bool isWholeTrack() const { return m_wholeTrack; }

        // Samples past the segment's end are ignored. A chunk with fewer
        // channels than the binner repeats its last channel.
        template <typename Sample>
        void addInterleaved(const Sample* samples, size_t frameCount, uint32_t chunkChannels) {
            if (!samples || chunkChannels == 0) {
                return;
            }

            size_t i = 0;
            while (i < frameCount && m_pos < m_end) {
                // Skips empty buckets too (tracks shorter than the bucket count)
                while (m_pos >= m_bucketEnd) {
                    m_bucketEnd = m_layout->end(++m_bucket);
                }

                const vDSP_Length n = static_cast<vDSP_Length>(
                    std::min<uint64_t>({frameCount - i, m_bucketEnd - m_pos, m_end - m_pos}));
                Accumulator& acc = m_buckets[m_bucket];

                for (uint32_t ch = 0; ch < m_channels; ch++) {
                    const Sample* src = samples + i * chunkChannels + std::min(ch, chunkChannels - 1);
                    double mn, mx, sumSq;
                    detail::runStats(src, static_cast<vDSP_Stride>(chunkChannels), n, mn, mx, sumSq);
                    acc.min[ch] = std::min(acc.min[ch], mn);
                    acc.max[ch] = std::max(acc.max[ch], mx);
                    acc.sumSq[ch] += sumSq;
                }
                acc.count += n;
                m_pos += n;
                i += n;
            }
        }

    private:
        friend class PeakBinner;

        Segment(PeakBinner& owner, size_t firstBucket, size_t lastBucket)
            : m_layout(&owner.m_layout)
            , m_buckets(owner.m_buckets.data())
            , m_channels(owner.m_channels)
            , m_wholeTrack(firstBucket == 0 && lastBucket == owner.m_layout.count())
            , m_bucket(firstBucket)
            , m_start(owner.m_layout.start(firstBucket))
            , m_pos(m_start)
            , m_end(firstBucket < lastBucket ? owner.m_layout.end(lastBucket - 1) : m_start)
            , m_bucketEnd(owner.m_layout.end(firstBucket))
        {}

        const BucketLayout* m_layout;
        Accumulator* m_buckets;
        uint32_t m_channels;
        bool m_wholeTrack;

        size_t m_bucket;
        uint64_t m_start;
        uint64_t m_pos;
        uint64_t m_end;
        uint64_t m_bucketEnd;
    };

    PeakBinner(uint32_t channels, uint32_t sampleRate, double duration,
               size_t bucketCount = WaveformData::BUCKET_COUNT)
        : m_channels(std::min(channels == 0 ? 2u : channels, 2u))
        , m_sampleRate(sampleRate)
        , m_duration(duration)
        , m_layout(declaredSampleCount(duration, sampleRate),
                   std::clamp<size_t>(bucketCount, 1, size_t{WaveformData::BUCKET_COUNT}))
        , m_buckets(m_layout.count())
    {}

    // Segments point into this binner
    PeakBinner(const PeakBinner&) = delete;
    PeakBinner& operator=(const PeakBinner&) = delete;

    // Buckets [firstBucket, lastBucket); an empty or out-of-range span is
    // clamped and reports done immediately.
    Segment segment(size_t firstBucket, size_t lastBucket) {
        lastBucket = std::min(lastBucket, m_layout.count());
        firstBucket = std::min(firstBucket, lastBucket);
        return Segment(*this, firstBucket, lastBucket);
    }

    Segment wholeTrack() { return segment(0, m_layout.count()); }

    // Discards everything accumulated, for a sequential retry after a failed
    // parallel pass. No segment may still be in use.
    void reset() { std::fill(m_buckets.begin(), m_buckets.end(), Accumulator{}); }

    // Buckets that received no samples (very short tracks, or a decoder that
    // ended early) stay zero.
    WaveformData finish() const {
        WaveformData data;
        data.initialize(m_channels, m_sampleRate, m_duration);

        for (size_t i = 0; i < m_buckets.size(); i++) {
            const Accumulator& acc = m_buckets[i];
            if (acc.count == 0) continue;
            for (uint32_t ch = 0; ch < m_channels; ch++) {
                data.min[ch][i] = static_cast<float>(acc.min[ch]);
                data.max[ch][i] = static_cast<float>(acc.max[ch]);
                data.rms[ch][i] = static_cast<float>(std::sqrt(acc.sumSq[ch] / static_cast<double>(acc.count)));
            }
        }
        return data;
    }

    const BucketLayout& layout() const { return m_layout; }

private:
    uint32_t m_channels;
    uint32_t m_sampleRate;
    double m_duration;
    BucketLayout m_layout;
    std::vector<Accumulator> m_buckets;
};

} // namespace waveseek
