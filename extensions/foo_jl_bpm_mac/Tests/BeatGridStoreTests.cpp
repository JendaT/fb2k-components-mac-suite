//
//  BeatGridStoreTests.cpp
//  foo_jl_bpm_mac
//
//  The stored grid: round trip, "analysed without a grid", and blobs of
//  another version or damaged ones reading as nothing stored.
//

#include "TestHarness.h"
#include "../src/Core/BeatGridStore.h"

#include <cstring>

using namespace bpm;

namespace {

BeatGrid sampleGrid() {
    BeatGrid g;
    g.valid = true;
    g.bpm = 128.0;
    g.anchorSeconds = 0.0937;
    g.tempoStrength = 0.71f;
    g.barPhase = 2;
    g.phrasePhaseBars = 5;
    g.phraseConfidence = 0.4f;
    g.source = BeatSource::Classic;
    BeatRegion a;
    a.startSeconds = 0.0937; a.beatSeconds = 0.46875; a.beatCount = 128;
    BeatRegion b;
    b.startSeconds = 60.1; b.beatSeconds = 0.46875; b.beatCount = 12; b.quiet = true;
    g.regions = { a, b };
    for (int i = 0; i < 90; i++) {
        g.bars.push_back({ static_cast<int8_t>(i % 7 - 3), static_cast<uint8_t>(i % 5), static_cast<uint8_t>(i * 3),
                           static_cast<uint8_t>(i == 40 ? jl_bar_region_start : 0) });
    }
    return g;
}

void testRoundTrip() {
    g_context = "round trip";
    const StoredGrid stored = toStored(sampleGrid());
    CHECK(stored.available, "a valid grid is available");
    CHECK_EQ(stored.regions.size(), 2, "regions");
    CHECK_EQ(stored.regions[1].flags, jl_region_quiet, "a quiet region keeps its flag");
    const std::vector<uint8_t> blob = encodeStoredGrid(stored);
    CHECK_EQ(blob.size(), 4 + 4 + 1 + 8 + 8 + 4 + 1 + 1 + 4 + 1 + 4 + 4 + 2 * 24 + 90 * 4, "blob size");
    const std::optional<StoredGrid> back = decodeStoredGrid(blob.data(), blob.size());
    CHECK(back.has_value(), "decoded");
    if (!back) return;
    CHECK(back->available, "available");
    CHECK(back->summary.bpm == 128.0 && back->summary.anchor_seconds == 0.0937, "BPM and anchor");
    CHECK(back->summary.tempo_strength == 0.71f && back->summary.phrase_confidence == 0.4f, "strength and confidence");
    CHECK(back->summary.bar_phase == 2 && back->summary.phrase_phase_bars == 5, "phases");
    bool regions = back->regions.size() == 2;
    for (size_t i = 0; regions && i < 2; i++) {
        regions = std::memcmp(&back->regions[i], &stored.regions[i], sizeof(jl_beat_region)) == 0;
    }
    CHECK(regions, "regions identical");
    bool bars = back->bars.size() == stored.bars.size();
    for (size_t i = 0; bars && i < stored.bars.size(); i++) {
        bars = std::memcmp(&back->bars[i], &stored.bars[i], sizeof(jl_bar_stat)) == 0;
    }
    CHECK(bars, "bars identical");
}

void testUnavailable() {
    g_context = "unavailable";
    const StoredGrid none = toStored(BeatGrid());
    CHECK(!none.available, "an invalid grid is stored as unavailable");
    const std::vector<uint8_t> blob = encodeStoredGrid(none);
    const std::optional<StoredGrid> back = decodeStoredGrid(blob.data(), blob.size());
    CHECK(back.has_value() && !back->available, "and reads back as analysed without a grid");
}

void testRejects() {
    g_context = "rejects";
    std::vector<uint8_t> blob = encodeStoredGrid(toStored(sampleGrid()));
    CHECK(!decodeStoredGrid(nullptr, 0).has_value(), "nothing");
    CHECK(!decodeStoredGrid(blob.data(), blob.size() - 1).has_value(), "truncated");
    std::vector<uint8_t> longer = blob;
    longer.push_back(0);
    CHECK(!decodeStoredGrid(longer.data(), longer.size()).has_value(), "trailing bytes");
    std::vector<uint8_t> other = blob;
    other[4] = static_cast<uint8_t>(kStoredGridVersion + 1);
    CHECK(!decodeStoredGrid(other.data(), other.size()).has_value(), "another format version reads as not analysed");
    std::vector<uint8_t> magic = blob;
    magic[0] = 'X';
    CHECK(!decodeStoredGrid(magic.data(), magic.size()).has_value(), "wrong magic");
    std::vector<uint8_t> bpm0 = blob;
    std::memset(bpm0.data() + 9, 0, 8);
    CHECK(!decodeStoredGrid(bpm0.data(), bpm0.size()).has_value(), "zero BPM");
}

void testLockedShare() {
    g_context = "locked share";
    std::vector<jl_bar_stat> bars(4, jl_bar_stat{ 0, 4, 64, 0 });
    bars[3] = { 40, 0, 64, 0 };
    CHECK_FLOAT_EQ(lockedShare(bars), 0.75, "three of four bars");
    CHECK_FLOAT_EQ(lockedShare({}), 0.0, "no bars");
}

} // namespace

int main() {
    testRoundTrip();
    testUnavailable();
    testRejects();
    testLockedShare();
    TEST_MAIN_END();
}
