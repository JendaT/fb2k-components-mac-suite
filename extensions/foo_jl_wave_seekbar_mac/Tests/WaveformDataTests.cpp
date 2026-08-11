//
//  WaveformDataTests.cpp
//  foo_wave_seekbar_mac
//

// TEST_LIBS: -lz

#include "TestSupport.h"
#include "../src/Core/WaveformData.h"

#include <cmath>
#include <limits>
#include <vector>

namespace {

// Deterministic, non-trivial content so serialization bugs that preserve
// structure but scramble values still show up.
WaveformData makeSampleData(uint32_t channels = 2) {
    WaveformData data;
    data.initialize(channels, 44100, 213.5);

    for (uint32_t ch = 0; ch < channels; ch++) {
        for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
            double phase = static_cast<double>(i) / WaveformData::BUCKET_COUNT;
            data.min[ch][i] = static_cast<float>(-std::sin(phase * 6.0) * (ch == 0 ? 0.9 : 0.4));
            data.max[ch][i] = static_cast<float>(std::sin(phase * 6.0) * (ch == 0 ? 0.8 : 0.5));
            data.rms[ch][i] = static_cast<float>(std::fabs(std::sin(phase * 3.0)) * 0.6);
        }
    }
    return data;
}

void testInitialize() {
    TEST_CASE("initialize");

    WaveformData data;
    data.initialize(2, 48000, 120.0);

    CHECK(data.channelCount == 2, "channel count is stored");
    CHECK(data.sampleRate == 48000, "sample rate is stored");
    CHECK_NEAR(data.duration, 120.0, 1e-9, "duration is stored");
    CHECK(data.min[0].size() == WaveformData::BUCKET_COUNT, "min buffer is allocated");
    CHECK(data.max[1].size() == WaveformData::BUCKET_COUNT, "max buffer is allocated for both channels");
    CHECK(data.rms[0].size() == WaveformData::BUCKET_COUNT, "rms buffer is allocated");

    // More than two channels is not supported; the surplus must be dropped
    // rather than written past the fixed two-channel arrays.
    WaveformData surround;
    surround.initialize(6, 44100, 10.0);
    CHECK(surround.channelCount == 2, "surround input is clamped to stereo");
}

void testValidity() {
    TEST_CASE("validity");

    CHECK(makeSampleData().isValid(), "fully populated data is valid");
    CHECK(makeSampleData(1).isValid(), "mono data is valid");

    WaveformData empty;
    CHECK(!empty.isValid(), "default-constructed data is not valid");

    WaveformData noRate = makeSampleData();
    noRate.sampleRate = 0;
    CHECK(!noRate.isValid(), "data without a sample rate is not valid");

    WaveformData noDuration = makeSampleData();
    noDuration.duration = 0.0;
    CHECK(!noDuration.isValid(), "data without a duration is not valid");

    WaveformData negativeDuration = makeSampleData();
    negativeDuration.duration = -5.0;
    CHECK(!negativeDuration.isValid(), "negative duration is not valid");

    // A NaN duration would otherwise pass a naive > 0 test and poison every
    // position calculation downstream.
    WaveformData nanDuration = makeSampleData();
    nanDuration.duration = std::numeric_limits<double>::quiet_NaN();
    CHECK(!nanDuration.isValid(), "NaN duration is not valid");

    WaveformData truncated = makeSampleData();
    truncated.max[1].resize(10);
    CHECK(!truncated.isValid(), "a short channel buffer is not valid");
}

void testSerializationRoundTrip() {
    TEST_CASE("serialization round trip");

    WaveformData original = makeSampleData();
    std::vector<uint8_t> bytes;
    original.serialize(bytes);
    CHECK(!bytes.empty(), "serialization produces bytes");

    WaveformData restored;
    CHECK(restored.deserialize(bytes.data(), bytes.size()), "serialized bytes deserialize");
    CHECK(restored.channelCount == original.channelCount, "channel count survives");
    CHECK(restored.sampleRate == original.sampleRate, "sample rate survives");
    CHECK_NEAR(restored.duration, original.duration, 1e-9, "duration survives");

    bool identical = true;
    for (uint32_t ch = 0; ch < original.channelCount && identical; ch++) {
        for (size_t i = 0; i < WaveformData::BUCKET_COUNT; i++) {
            if (restored.min[ch][i] != original.min[ch][i] ||
                restored.max[ch][i] != original.max[ch][i] ||
                restored.rms[ch][i] != original.rms[ch][i]) {
                identical = false;
                break;
            }
        }
    }
    CHECK(identical, "every bucket survives serialization bit-for-bit");
}

void testDeserializeRejectsBadInput() {
    TEST_CASE("deserialize rejects bad input");

    WaveformData original = makeSampleData();
    std::vector<uint8_t> bytes;
    original.serialize(bytes);

    WaveformData target;
    CHECK(!target.deserialize(nullptr, 0), "null input is rejected");
    CHECK(!target.deserialize(bytes.data(), 4), "a truncated header is rejected");
    CHECK(!target.deserialize(bytes.data(), bytes.size() / 2), "truncated payload is rejected");

    // Cache rows can be corrupted or written by a future format version.
    std::vector<uint8_t> garbage(256, 0xAB);
    CHECK(!target.deserialize(garbage.data(), garbage.size()), "garbage is rejected");
}

void testCompressionRoundTrip() {
    TEST_CASE("compression round trip");

    WaveformData original = makeSampleData();
    std::vector<uint8_t> packed = original.compress();
    CHECK(!packed.empty(), "compression produces bytes");

    auto restored = WaveformData::decompress(packed.data(), packed.size());
    CHECK(restored.has_value(), "compressed bytes decompress");
    if (restored) {
        CHECK(restored->isValid(), "decompressed data is valid");
        CHECK(restored->channelCount == original.channelCount, "channel count survives compression");
        CHECK_NEAR(restored->duration, original.duration, 1e-9, "duration survives compression");
        CHECK_NEAR(restored->max[0][100], original.max[0][100], 1e-9, "bucket values survive compression");
        CHECK_NEAR(restored->rms[1][2000], original.rms[1][2000], 1e-9, "late buckets survive compression");
    }
}

void testDecompressRejectsBadInput() {
    TEST_CASE("decompress rejects bad input");

    CHECK(!WaveformData::decompress(nullptr, 0).has_value(), "null input is rejected");

    std::vector<uint8_t> garbage(512, 0x7F);
    CHECK(!WaveformData::decompress(garbage.data(), garbage.size()).has_value(),
          "non-zlib input is rejected");

    // A valid stream truncated mid-way must fail rather than yield a
    // half-filled waveform.
    WaveformData original = makeSampleData();
    std::vector<uint8_t> packed = original.compress();
    CHECK(!WaveformData::decompress(packed.data(), packed.size() / 2).has_value(),
          "a truncated stream is rejected");
}

void testPositionAccessors() {
    TEST_CASE("position accessors");

    WaveformData data;
    data.initialize(2, 44100, 100.0);
    data.max[0][0] = 0.1f;
    data.max[0][WaveformData::BUCKET_COUNT - 1] = 0.9f;
    data.min[0][WaveformData::BUCKET_COUNT - 1] = -0.9f;
    data.rms[0][WaveformData::BUCKET_COUNT - 1] = 0.5f;

    CHECK_NEAR(data.getMaxAt(0, 0.0), 0.1, 1e-6, "track start reads the first bucket");
    CHECK_NEAR(data.getMaxAt(0, 1.0), 0.9, 1e-6, "track end reads the last bucket");
    CHECK_NEAR(data.getMinAt(0, 1.0), -0.9, 1e-6, "min reads the last bucket");
    CHECK_NEAR(data.getRmsAt(0, 1.0), 0.5, 1e-6, "rms reads the last bucket");

    // Out-of-range positions and channels must return silence, not read out
    // of bounds.
    CHECK_NEAR(data.getMaxAt(0, 5.0), 0.9, 1e-6, "a position past the end clamps to the last bucket");
    CHECK_NEAR(data.getMaxAt(0, -1.0), 0.1, 1e-6, "a negative position clamps to the first bucket");
    CHECK_NEAR(data.getMaxAt(7, 0.5), 0.0, 1e-6, "an unknown channel reads as silence");

    WaveformData mono;
    mono.initialize(1, 44100, 10.0);
    CHECK_NEAR(mono.getMaxAt(1, 0.5), 0.0, 1e-6, "the absent channel of mono data reads as silence");
}

void testMemorySize() {
    TEST_CASE("memory size");

    WaveformData stereo = makeSampleData(2);
    WaveformData mono = makeSampleData(1);

    CHECK(stereo.memorySize() > mono.memorySize(), "stereo data costs more than mono");
    // 2 channels * 3 arrays * 2048 buckets * 4 bytes, plus the struct itself.
    CHECK(stereo.memorySize() >= 2 * 3 * WaveformData::BUCKET_COUNT * sizeof(float),
          "reported size covers the bucket arrays");
}

} // namespace

int main() {
    testInitialize();
    testValidity();
    testSerializationRoundTrip();
    testDeserializeRejectsBadInput();
    testCompressionRoundTrip();
    testDecompressRejectsBadInput();
    testPositionAccessors();
    testMemorySize();
    return testsupport::summarize("WaveformDataTests");
}
