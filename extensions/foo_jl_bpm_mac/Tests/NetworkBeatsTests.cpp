//
//  NetworkBeatsTests.cpp
//  foo_jl_bpm_mac
//
//  Chunking and peak picking around the beat network, against values from
//  upstream's split_piece and minimal postprocessor (beat_this 1.1.0).
//

// TEST_DEPS: src/Core/BeatGridAnalyzer.cpp src/Core/TempoEstimator.cpp

#include "TestHarness.h"
#include "../src/Core/NetworkBeats.h"

#include <cmath>
#include <vector>

using namespace bpm;

namespace {

void testChunkStarts() {
    g_context = "chunk starts";
    // upstream split_piece(spect, 1500, 6, avoid_short_end=True)
    CHECK(networkChunkStarts(100) == std::vector<long>({ -6 }), "short piece: one chunk");
    CHECK(networkChunkStarts(1488) == std::vector<long>({ -6 }), "exactly one step");
    CHECK(networkChunkStarts(1489) == std::vector<long>({ -6, -5 }), "one frame more: the last moves back");
    CHECK(networkChunkStarts(1500) == std::vector<long>({ -6, 6 }), "1500 frames");
    CHECK(networkChunkStarts(3000) == std::vector<long>({ -6, 1482, 1506 }), "3000 frames");
    const std::vector<long> ten = networkChunkStarts(30000);
    CHECK_EQ(ten.size(), 21, "10 minutes: 21 chunks");
    CHECK_EQ(ten[1], 1482, "step 1488");
    CHECK_EQ(ten.back(), 28506, "the last ends on the piece's end");
    CHECK(networkChunkStarts(0).empty(), "nothing in, nothing out");
}

void testChunkInputAndMerge() {
    g_context = "chunk input";
    const long frames = 100, bins = 2;
    std::vector<float> spect(frames * bins);
    for (long i = 0; i < frames * bins; i++) spect[static_cast<size_t>(i)] = static_cast<float>(i);
    std::vector<float> chunk;
    const long rows = chunkInput(spect, frames, bins, -6, chunk);
    CHECK_EQ(rows, 112, "6 padded + 100 + 6 padded, as upstream");
    CHECK(chunk[0] == 0.0f && chunk[5 * bins] == 0.0f, "left padding is zero");
    CHECK(chunk[6 * bins] == 0.0f && chunk[6 * bins + 1] == 1.0f, "row 6 is frame 0");
    CHECK(chunk[(rows - 1) * bins] == 0.0f, "right padding is zero");

    g_context = "merge";
    std::vector<float> piece(3000, -1000.0f);
    std::vector<bool> filled(3000, false);
    for (long start : networkChunkStarts(3000)) {
        std::vector<float> pred(kNetworkChunk, static_cast<float>(start));
        mergeChunk(pred, kNetworkChunk, start, piece, filled);
    }
    CHECK(piece[0] == -6.0f && piece[1487] == -6.0f, "first chunk's frames, borders dropped");
    CHECK(piece[1488] == 1482.0f, "then the second chunk's");
    CHECK(piece[2975] == 1482.0f, "earlier chunks win the overlap");
    CHECK(piece[2976] == 1506.0f && piece[2993] == 1506.0f, "the last chunk fills the end");
    bool all = true;
    for (bool f : filled) all = all && f;
    CHECK(all, "every frame filled: the first chunk is padded, the last ends border frames past the end");
    CHECK(piece[2999] == 1506.0f, "the last frame from the last chunk");
}

void testPeaks() {
    g_context = "peaks";
    // upstream: beats [20, 60.5, 140, 180] (frames); ours adds sub-frame refinement
    std::vector<float> x(200, -5.0f);
    x[20] = 3.0f; x[21] = 2.0f; x[60] = 1.0f; x[61] = 1.0f; x[100] = -0.5f; x[140] = 4.0f; x[143] = 3.9f; x[180] = 2.0f;
    const std::vector<double> p = pickPeaks(x);
    CHECK_EQ(p.size(), 4, "four peaks");
    CHECK(p[0] > 20.0 && p[0] < 20.5, "pulled towards the higher neighbour");
    CHECK(p[1] == 60.5, "a two-frame plateau merges to its middle");
    CHECK(std::fabs(p[2] - 140.0) < 1e-9, "a weaker peak within 3 frames is dropped; symmetric neighbours stay put");
    CHECK(std::fabs(p[3] - 180.0) < 1e-9, "isolated peak");

    std::vector<float> smooth(100, -5.0f);
    for (int k = 40; k <= 44; k++) smooth[k] = 2.0f - 0.5f * float((k - 42.3) * (k - 42.3));
    const std::vector<double> q = pickPeaks(smooth);
    CHECK(q.size() == 1 && std::fabs(q[0] - 42.3) < 0.05, "parabola finds a peak between frames");
}

void testNetworkBeats() {
    g_context = "beats";
    std::vector<float> beat(500, -6.0f), down(500, -6.0f);
    for (int k = 25; k < 500; k += 25) beat[k] = 4.0f;   // 120 BPM at 50 fps
    for (int k = 26; k < 500; k += 100) down[k] = 3.0f;   // a frame late: moves to the beat
    const RawBeats raw = networkBeats(beat, down);
    CHECK(raw.source == BeatSource::BeatThis, "source");
    CHECK_EQ(raw.beats.size(), 19, "19 beats");
    CHECK(std::fabs(raw.beats[0] - 0.5) < 1e-9, "frame 25 = 0.5 s");
    CHECK_EQ(raw.downbeats.size(), 5, "5 downbeats");
    CHECK(std::fabs(raw.downbeats[0] - 0.5) < 1e-9, "downbeat on its nearest beat");
    CHECK_EQ(raw.confidence.size(), raw.beats.size(), "a confidence per beat");
    CHECK(std::fabs(raw.confidence[0] - 1.0f / (1.0f + std::exp(-4.0f))) < 1e-6, "sigmoid of the peak logit");
}

// The streamed run equals upstream's split of the whole piece: a fake
// network that writes, per row, the chunk's start plus the row's first value
void testChunkerMatchesWholePiece() {
    g_context = "chunker";
    const long bins = 3;
    auto fake = [](const float *input, long rows, float *beat, float *downbeat) {
        for (long r = 0; r < rows; r++) {
            beat[r] = input[r * 3] + 0.25f * static_cast<float>(rows);   // depends on the chunk's rows and content
            downbeat[r] = -input[r * 3 + 1];
        }
        return true;
    };
    for (long frames : { 50L, 1488L, 1489L, 1500L, 1505L, 2982L, 2983L, 3000L, 4470L, 30001L }) {
        std::vector<float> spect(static_cast<size_t>(frames * bins));
        for (long i = 0; i < frames * bins; i++) spect[static_cast<size_t>(i)] = static_cast<float>((i * 7919) % 1000) / 10.0f;
        // Whole piece, as upstream
        std::vector<float> wholeBeat(static_cast<size_t>(frames), -1000.0f), wholeDown = wholeBeat;
        std::vector<bool> filledB(static_cast<size_t>(frames), false), filledD = filledB;
        for (long start : networkChunkStarts(frames)) {
            std::vector<float> in, b, d;
            const long rows = chunkInput(spect, frames, bins, start, in);
            b.resize(static_cast<size_t>(rows)); d.resize(static_cast<size_t>(rows));
            fake(in.data(), rows, b.data(), d.data());
            mergeChunk(b, rows, start, wholeBeat, filledB);
            mergeChunk(d, rows, start, wholeDown, filledD);
        }
        // Streamed in uneven pieces
        for (long step : { 1L, 37L, 1500L }) {
            NetworkChunker chunker(bins, fake);
            for (long f = 0; f < frames; f += step) chunker.add(spect.data() + f * bins, std::min(step, frames - f));
            CHECK(chunker.finish(), "finishes");
            const bool same = chunker.beatLogits() == wholeBeat && chunker.downbeatLogits() == wholeDown;
            if (!same) printf("    differs: %ld frames in steps of %ld\n", frames, step);
            CHECK(same, "identical to the whole-piece run");
        }
    }
    NetworkChunker failing(bins, [](const float *, long, float *, float *) { return false; });
    std::vector<float> two(static_cast<size_t>(2000 * bins), 0.0f);
    CHECK(!failing.add(two.data(), 2000), "a failing network stops it");
    CHECK(!failing.finish(), "and finish reports it");
}

} // namespace

int main() {
    testChunkStarts();
    testChunkInputAndMerge();
    testPeaks();
    testNetworkBeats();
    testChunkerMatchesWholePiece();
    TEST_MAIN_END();
}
