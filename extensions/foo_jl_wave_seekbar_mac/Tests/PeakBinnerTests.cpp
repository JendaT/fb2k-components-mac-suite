//
//  PeakBinnerTests.cpp
//  foo_wave_seekbar_mac
//

// TEST_DEPS: src/Core/WaveformData.cpp
// TEST_LIBS: -lz -framework Accelerate

#include "TestSupport.h"
#include "../src/Core/PeakBinner.h"

#include <limits>
#include <vector>

using namespace waveseek;

namespace {

// 4 buckets of 2 samples each: sampleRate 1 and duration 8 mean 8 declared
// samples, so the arithmetic in every case below is checkable by hand.
// Returned as a prvalue - the binner is not copyable, since segments point
// into it.
PeakBinner makeBinner(uint32_t channels) {
    return PeakBinner(channels, /*sampleRate*/ 1, /*duration*/ 8.0, /*bucketCount*/ 4);
}

template <typename Sample>
void feedWhole(PeakBinner& binner, const std::vector<Sample>& samples, uint32_t channels) {
    PeakBinner::Segment segment = binner.wholeTrack();
    segment.addInterleaved(samples.data(), samples.size() / channels, channels);
}

void testBucketLayout() {
    TEST_CASE("bucket layout");

    BucketLayout even(8, 4);
    CHECK(even.start(0) == 0 && even.start(1) == 2 && even.start(2) == 4 && even.start(3) == 6,
          "8 samples over 4 buckets start every 2");
    CHECK(even.end(2) == 6, "a bucket ends where the next starts");
    CHECK(even.end(3) == std::numeric_limits<uint64_t>::max(), "last bucket is open-ended");

    // Uneven division spreads the remainder instead of dropping it
    BucketLayout uneven(10, 4);
    CHECK(uneven.start(1) == 2 && uneven.start(2) == 5 && uneven.start(3) == 7,
          "10 samples over 4 buckets split 2/3/2/3");

    // 10s at 44.1kHz: the old fixed 215-sample buckets covered 440320 of the
    // 441000 samples and dropped the rest
    BucketLayout real(441000, WaveformData::BUCKET_COUNT);
    bool sizesOk = true;
    for (size_t b = 0; b + 1 < WaveformData::BUCKET_COUNT; b++) {
        uint64_t size = real.end(b) - real.start(b);
        sizesOk = sizesOk && (size == 215 || size == 216);
    }
    CHECK(sizesOk, "bucket sizes differ by at most one sample");
    uint64_t lastSize = 441000 - real.start(WaveformData::BUCKET_COUNT - 1);
    CHECK(lastSize == 215 || lastSize == 216, "last bucket reaches the declared end");

    BucketLayout empty(0, 4);
    CHECK(empty.start(3) == 0 && empty.end(3) == std::numeric_limits<uint64_t>::max(),
          "zero length is treated as one sample, all in the last bucket");
}

void testDeclaredSampleCount() {
    TEST_CASE("declared sample count");

    CHECK(declaredSampleCount(10.0, 44100) == 441000, "duration times rate");
    CHECK(declaredSampleCount(0.0, 44100) == 1, "zero duration falls back to 1");
    CHECK(declaredSampleCount(-3.0, 44100) == 1, "negative duration falls back to 1");
    CHECK(declaredSampleCount(5.0, 0) == 1, "zero sample rate falls back to 1");
    CHECK(declaredSampleCount(std::numeric_limits<double>::quiet_NaN(), 44100) == 1,
          "NaN duration falls back to 1 instead of an undefined cast");
    CHECK(declaredSampleCount(std::numeric_limits<double>::infinity(), 44100) == 1,
          "infinite duration falls back to 1 instead of an undefined cast");

    // Clamped so bucket * total cannot overflow in BucketLayout
    uint64_t huge = declaredSampleCount(1e300, 44100);
    BucketLayout layout(huge, WaveformData::BUCKET_COUNT);
    CHECK(layout.start(WaveformData::BUCKET_COUNT / 2) == huge / 2, "huge length does not wrap");
}

void testConstantSignal() {
    TEST_CASE("constant mono signal");

    PeakBinner binner = makeBinner(1);
    feedWhole(binner, std::vector<float>(8, 0.5f), 1);
    WaveformData data = binner.finish();

    for (size_t i = 0; i < 4; i++) {
        CHECK_NEAR(data.min[0][i], 0.5, 1e-6, "min of a constant block is the constant");
        CHECK_NEAR(data.max[0][i], 0.5, 1e-6, "max of a constant block is the constant");
        CHECK_NEAR(data.rms[0][i], 0.5, 1e-6, "RMS of a constant block is the constant");
    }
}

void testFullScaleAlternating() {
    TEST_CASE("full-scale alternating signal");

    PeakBinner binner = makeBinner(1);
    feedWhole(binner, std::vector<double>{1.0, -1.0, 1.0, -1.0, 1.0, -1.0, 1.0, -1.0}, 1);
    WaveformData data = binner.finish();

    for (size_t i = 0; i < 4; i++) {
        CHECK_NEAR(data.min[0][i], -1.0, 1e-6, "min reaches negative full scale");
        CHECK_NEAR(data.max[0][i], 1.0, 1e-6, "max reaches positive full scale");
        // sqrt((1 + 1) / 2) == 1
        CHECK_NEAR(data.rms[0][i], 1.0, 1e-6, "RMS of a square wave is its amplitude");
    }
}

void testBucketsAreIndependent() {
    TEST_CASE("buckets are independent");

    // A loud first bucket must not bleed into a quiet second one
    PeakBinner binner = makeBinner(1);
    feedWhole(binner, std::vector<float>{1.0f, -1.0f, 0.1f, -0.1f, 0.0f, 0.0f, 0.0f, 0.0f}, 1);
    WaveformData data = binner.finish();

    CHECK_NEAR(data.max[0][0], 1.0, 1e-6, "first bucket keeps its own peak");
    CHECK_NEAR(data.max[0][1], 0.1, 1e-6, "second bucket is not polluted by the first");
    CHECK_NEAR(data.min[0][1], -0.1, 1e-6, "second bucket min is its own");
    CHECK_NEAR(data.max[0][2], 0.0, 1e-6, "silent bucket stays silent");
}

void testChunkBoundariesDoNotMatter() {
    TEST_CASE("chunk boundaries do not matter");

    // The same samples one at a time and in one block. Values are multiples
    // of 1/8, so every sum of squares is exact and results compare equal.
    std::vector<double> samples = {0.5, -0.25, 0.75, 0.125, -1.0, 0.375, 0.0, -0.625};

    PeakBinner whole = makeBinner(1);
    feedWhole(whole, samples, 1);

    PeakBinner single = makeBinner(1);
    PeakBinner::Segment segment = single.wholeTrack();
    for (double s : samples) {
        segment.addInterleaved(&s, 1, 1);
    }

    WaveformData a = whole.finish();
    WaveformData b = single.finish();
    CHECK(a.min[0] == b.min[0] && a.max[0] == b.max[0] && a.rms[0] == b.rms[0],
          "frame-by-frame feeding matches one block");
}

void testPastDeclaredLength() {
    TEST_CASE("samples past the declared length");

    // The declared length is an estimate: 4 surplus samples land in the last
    // bucket instead of being dropped, and earlier buckets are untouched
    PeakBinner binner = makeBinner(1);
    PeakBinner::Segment segment = binner.wholeTrack();
    std::vector<float> samples(8, 0.5f);
    samples.insert(samples.end(), 4, 1.0f);
    segment.addInterleaved(samples.data(), samples.size(), 1);
    WaveformData data = binner.finish();

    CHECK(!segment.done(), "the whole-track segment runs until the decoder ends");
    CHECK_NEAR(data.max[0][2], 0.5, 1e-6, "earlier buckets are untouched");
    CHECK_NEAR(data.max[0][3], 1.0, 1e-6, "surplus samples join the last bucket");
    // (2 * 0.25 + 4 * 1) / 6 == 0.75
    CHECK_NEAR(data.rms[0][3], std::sqrt(0.75), 1e-6, "last bucket RMS counts the surplus");
}

void testShortDelivery() {
    TEST_CASE("decoder ends early");

    // Only 3 of the 8 declared samples arrive: buckets past the data stay zero
    PeakBinner binner = makeBinner(1);
    feedWhole(binner, std::vector<float>{0.9f, 0.9f, 0.4f}, 1);
    WaveformData data = binner.finish();

    CHECK_NEAR(data.max[0][0], 0.9, 1e-6, "first bucket holds real data");
    CHECK_NEAR(data.max[0][1], 0.4, 1e-6, "partial bucket holds the remainder");
    CHECK_NEAR(data.rms[0][1], 0.4, 1e-6, "partial bucket RMS divides by the samples it saw");
    CHECK_NEAR(data.max[0][2], 0.0, 1e-6, "unreached bucket is zero");
    CHECK_NEAR(data.min[0][3], 0.0, 1e-6, "trailing bucket is zero");
    CHECK_NEAR(data.rms[0][3], 0.0, 1e-6, "trailing RMS is zero");
}

void testTrackShorterThanBucketCount() {
    TEST_CASE("track shorter than the bucket count");

    // 3 samples over 8 buckets: bucket b starts at 3b/8, so samples land in
    // buckets 2, 5 and 7 and the rest stay empty
    PeakBinner binner(1, 1, 3.0, 8);
    feedWhole(binner, std::vector<float>{0.25f, 0.5f, 0.75f}, 1);
    WaveformData data = binner.finish();

    CHECK_NEAR(data.max[0][2], 0.25, 1e-6, "first sample lands in bucket 2");
    CHECK_NEAR(data.max[0][5], 0.5, 1e-6, "second sample lands in bucket 5");
    CHECK_NEAR(data.max[0][7], 0.75, 1e-6, "third sample lands in the last bucket");
    bool othersEmpty = true;
    for (size_t i : {0, 1, 3, 4, 6}) {
        othersEmpty = othersEmpty && data.max[0][i] == 0.0f && data.min[0][i] == 0.0f && data.rms[0][i] == 0.0f;
    }
    CHECK(othersEmpty, "buckets without samples are zero");
}

void testStereoSeparation() {
    TEST_CASE("stereo channel separation");

    PeakBinner binner = makeBinner(2);
    // Interleaved L/R: left rides high, right rides low
    std::vector<float> samples;
    for (int i = 0; i < 8; i++) {
        samples.push_back(0.5f);
        samples.push_back(-0.25f);
    }
    feedWhole(binner, samples, 2);
    WaveformData data = binner.finish();

    CHECK(data.channelCount == 2, "stereo data reports two channels");
    for (size_t i = 0; i < 4; i++) {
        CHECK_NEAR(data.max[0][i], 0.5, 1e-6, "left channel keeps its own peak");
        CHECK_NEAR(data.max[1][i], -0.25, 1e-6, "right channel keeps its own peak");
        CHECK_NEAR(data.min[1][i], -0.25, 1e-6, "right channel min is its own");
    }
}

void testFewerChunkChannelsThanTrack() {
    TEST_CASE("chunk with fewer channels than the track");

    // A mono chunk delivered to a stereo binner shows on both channels
    // instead of leaving the second one flat
    PeakBinner binner = makeBinner(2);
    feedWhole(binner, std::vector<float>(8, 0.75f), 1);
    WaveformData data = binner.finish();

    CHECK_NEAR(data.max[0][0], 0.75, 1e-6, "present channel is binned");
    CHECK_NEAR(data.max[1][0], 0.75, 1e-6, "missing channel repeats the last one");
    CHECK_NEAR(data.rms[1][3], 0.75, 1e-6, "missing channel RMS repeats too");
}

void testMoreChunkChannelsThanTrack() {
    TEST_CASE("chunk with more channels than the track");

    // A 3-channel chunk into a stereo binner: the third channel is skipped
    PeakBinner binner = makeBinner(2);
    std::vector<float> samples;
    for (int i = 0; i < 8; i++) {
        samples.push_back(0.25f);
        samples.push_back(0.5f);
        samples.push_back(1.0f);
    }
    feedWhole(binner, samples, 3);
    WaveformData data = binner.finish();

    CHECK_NEAR(data.max[0][1], 0.25, 1e-6, "first channel is channel 0");
    CHECK_NEAR(data.max[1][1], 0.5, 1e-6, "second channel is channel 1");
}

void testSegmentBounds() {
    TEST_CASE("segment bounds");

    PeakBinner binner = makeBinner(1);
    PeakBinner::Segment middle = binner.segment(1, 3);
    CHECK(middle.startSample() == 2, "segment starts at its first bucket");
    CHECK(!middle.isWholeTrack(), "a partial segment is not the whole track");
    CHECK(binner.wholeTrack().isWholeTrack(), "the whole-track segment says so");

    // A decoder that keeps going past the segment: only buckets 1 and 2 fill
    std::vector<float> samples(6, 1.0f);
    middle.addInterleaved(samples.data(), samples.size(), 1);
    CHECK(middle.done(), "segment is done after its last sample");
    WaveformData data = binner.finish();

    CHECK_NEAR(data.max[0][0], 0.0, 1e-6, "bucket before the segment is untouched");
    CHECK_NEAR(data.max[0][1], 1.0, 1e-6, "first segment bucket filled");
    CHECK_NEAR(data.max[0][2], 1.0, 1e-6, "last segment bucket filled");
    CHECK_NEAR(data.max[0][3], 0.0, 1e-6, "samples past the segment end are ignored");

    PeakBinner::Segment empty = binner.segment(3, 3);
    CHECK(empty.done(), "an empty segment is done immediately");
    PeakBinner::Segment clamped = binner.segment(2, 99);
    CHECK(clamped.startSample() == 4 && !clamped.done(), "an over-long span is clamped to the last bucket");
}

void testSegmentsMatchSequentialPass() {
    TEST_CASE("segments match a sequential pass");

    // 1000 samples over 16 buckets, decoded once front to back in chunks of
    // 7, and again as 5 segments in reverse order in chunks of 3, each fed
    // from its start sample to the end of the track. Multiples of 1/16 keep
    // every sum exact, so the results must compare equal.
    const size_t total = 1000;
    std::vector<double> samples(total * 2);
    for (size_t i = 0; i < samples.size(); i++) {
        samples[i] = static_cast<double>(static_cast<int>((i * 7919) % 33) - 16) / 16.0;
    }

    PeakBinner sequential(2, 1, static_cast<double>(total), 16);
    PeakBinner::Segment whole = sequential.wholeTrack();
    for (size_t pos = 0; pos < total; pos += 7) {
        whole.addInterleaved(samples.data() + pos * 2, std::min<size_t>(7, total - pos), 2);
    }

    PeakBinner segmented(2, 1, static_cast<double>(total), 16);
    const size_t segments = 5;
    for (size_t seg = segments; seg-- > 0;) {
        PeakBinner::Segment segment = segmented.segment(seg * 16 / segments, (seg + 1) * 16 / segments);
        for (size_t pos = segment.startSample(); pos < total && !segment.done(); pos += 3) {
            segment.addInterleaved(samples.data() + pos * 2, std::min<size_t>(3, total - pos), 2);
        }
    }

    WaveformData a = sequential.finish();
    WaveformData b = segmented.finish();
    bool same = true;
    for (uint32_t ch = 0; ch < 2; ch++) {
        same = same && a.min[ch] == b.min[ch] && a.max[ch] == b.max[ch] && a.rms[ch] == b.rms[ch];
    }
    CHECK(same, "segmented result equals the sequential one");
    CHECK(a.rms[0][0] > 0.0f && a.rms[1][15] > 0.0f, "the comparison is over real data");
}

void testReset() {
    TEST_CASE("reset");

    // The scanner's fallback: a failed parallel pass is discarded before the
    // sequential retry, so partial segments cannot add to it twice
    PeakBinner binner = makeBinner(1);
    PeakBinner::Segment partial = binner.segment(0, 2);
    std::vector<float> loud(4, 1.0f);
    partial.addInterleaved(loud.data(), loud.size(), 1);
    binner.reset();

    feedWhole(binner, std::vector<float>(8, 0.25f), 1);
    WaveformData data = binner.finish();
    CHECK_NEAR(data.max[0][0], 0.25, 1e-6, "earlier samples are gone");
    CHECK_NEAR(data.rms[0][1], 0.25, 1e-6, "earlier sample counts are gone");
}

void testEmptyInputIsSafe() {
    TEST_CASE("empty and null input");

    PeakBinner binner = makeBinner(1);
    PeakBinner::Segment segment = binner.wholeTrack();
    segment.addInterleaved<float>(nullptr, 16, 1);
    std::vector<float> samples = {0.5f};
    segment.addInterleaved(samples.data(), 0, 1);
    segment.addInterleaved(samples.data(), 1, 0);

    // Had any of those advanced the position, these would land later
    std::vector<float> real(2, 0.5f);
    segment.addInterleaved(real.data(), real.size(), 1);
    WaveformData data = binner.finish();

    CHECK_NEAR(data.max[0][0], 0.5, 1e-6, "empty input consumed no positions");
    CHECK_NEAR(data.max[0][1], 0.0, 1e-6, "no data means silence");
}

void testProducesValidWaveformData() {
    TEST_CASE("produces valid WaveformData");

    // Full-size run: the result must satisfy the same isValid() the renderer
    // gates on
    PeakBinner binner(2, 44100, 1.0);
    feedWhole(binner, std::vector<float>(2 * 44100, 0.3f), 2);
    WaveformData data = binner.finish();

    CHECK(data.isValid(), "scanned data passes isValid");
    CHECK(data.min[0].size() == WaveformData::BUCKET_COUNT, "min buffer is fully sized");
    CHECK_NEAR(data.getMaxAt(0, 0.5), 0.3, 1e-6, "mid-track lookup returns the signal");
    CHECK_NEAR(data.getMaxAt(1, 0.999), 0.3, 1e-6, "the last bucket is filled");
}

} // namespace

int main() {
    testBucketLayout();
    testDeclaredSampleCount();
    testConstantSignal();
    testFullScaleAlternating();
    testBucketsAreIndependent();
    testChunkBoundariesDoNotMatter();
    testPastDeclaredLength();
    testShortDelivery();
    testTrackShorterThanBucketCount();
    testStereoSeparation();
    testFewerChunkChannelsThanTrack();
    testMoreChunkChannelsThanTrack();
    testSegmentBounds();
    testSegmentsMatchSequentialPass();
    testReset();
    testEmptyInputIsSafe();
    testProducesValidWaveformData();
    return testsupport::summarize("PeakBinnerTests");
}
