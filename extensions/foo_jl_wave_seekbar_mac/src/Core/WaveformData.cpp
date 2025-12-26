//
//  WaveformData.cpp
//  foo_wave_seekbar_mac
//
//  Core data structure for waveform peak data
//

#include "WaveformData.h"
#include <zlib.h>
#include <cstring>
#include <cmath>
#include <algorithm>

void WaveformData::initialize(uint32_t channels, uint32_t rate, double dur) {
    channelCount = std::min(channels, 2u);
    sampleRate = rate;
    duration = dur;

    for (uint32_t ch = 0; ch < channelCount; ch++) {
        min[ch].resize(BUCKET_COUNT, 0.0f);
        max[ch].resize(BUCKET_COUNT, 0.0f);
        rms[ch].resize(BUCKET_COUNT, 0.0f);
    }
}

bool WaveformData::isValid() const {
    if (channelCount == 0 || channelCount > 2) return false;
    if (sampleRate == 0) return false;
    if (duration <= 0) return false;

    for (uint32_t ch = 0; ch < channelCount; ch++) {
        if (min[ch].size() != BUCKET_COUNT) return false;
        if (max[ch].size() != BUCKET_COUNT) return false;
        if (rms[ch].size() != BUCKET_COUNT) return false;
    }

    return true;
}

size_t WaveformData::memorySize() const {
    size_t size = sizeof(WaveformData);
    for (uint32_t ch = 0; ch < channelCount; ch++) {
        size += min[ch].capacity() * sizeof(float);
        size += max[ch].capacity() * sizeof(float);
        size += rms[ch].capacity() * sizeof(float);
    }
    return size;
}

float WaveformData::getMinAt(uint32_t channel, double normalizedPosition) const {
    if (channel >= channelCount || min[channel].empty()) return 0.0f;
    size_t index = static_cast<size_t>(normalizedPosition * (BUCKET_COUNT - 1));
    index = std::min(index, BUCKET_COUNT - 1);
    return min[channel][index];
}

float WaveformData::getMaxAt(uint32_t channel, double normalizedPosition) const {
    if (channel >= channelCount || max[channel].empty()) return 0.0f;
    size_t index = static_cast<size_t>(normalizedPosition * (BUCKET_COUNT - 1));
    index = std::min(index, BUCKET_COUNT - 1);
    return max[channel][index];
}

float WaveformData::getRmsAt(uint32_t channel, double normalizedPosition) const {
    if (channel >= channelCount || rms[channel].empty()) return 0.0f;
    size_t index = static_cast<size_t>(normalizedPosition * (BUCKET_COUNT - 1));
    index = std::min(index, BUCKET_COUNT - 1);
    return rms[channel][index];
}

// Little-endian serialization helpers
template<typename T>
void WaveformData::writeLE(std::vector<uint8_t>& out, T value) {
    for (size_t i = 0; i < sizeof(T); i++) {
        out.push_back(static_cast<uint8_t>(value & 0xFF));
        value >>= 8;
    }
}

template<>
void WaveformData::writeLE<float>(std::vector<uint8_t>& out, float value) {
    uint32_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    writeLE(out, bits);
}

template<>
void WaveformData::writeLE<double>(std::vector<uint8_t>& out, double value) {
    uint64_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    writeLE(out, bits);
}

template<typename T>
T WaveformData::readLE(const uint8_t* data) {
    T value = 0;
    for (size_t i = 0; i < sizeof(T); i++) {
        value |= static_cast<T>(data[i]) << (i * 8);
    }
    return value;
}

template<>
float WaveformData::readLE<float>(const uint8_t* data) {
    uint32_t bits = readLE<uint32_t>(data);
    float value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

template<>
double WaveformData::readLE<double>(const uint8_t* data) {
    uint64_t bits = readLE<uint64_t>(data);
    double value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

void WaveformData::serialize(std::vector<uint8_t>& out) const {
    out.clear();
    out.reserve(4 + 4 + 4 + 8 + channelCount * 3 * BUCKET_COUNT * sizeof(float));

    // Header
    writeLE(out, SERIALIZATION_VERSION);
    writeLE(out, channelCount);
    writeLE(out, sampleRate);
    writeLE(out, duration);

    // Per-channel data
    for (uint32_t ch = 0; ch < channelCount; ch++) {
        for (size_t i = 0; i < BUCKET_COUNT; i++) {
            writeLE(out, min[ch][i]);
        }
        for (size_t i = 0; i < BUCKET_COUNT; i++) {
            writeLE(out, max[ch][i]);
        }
        for (size_t i = 0; i < BUCKET_COUNT; i++) {
            writeLE(out, rms[ch][i]);
        }
    }
}

bool WaveformData::deserialize(const uint8_t* data, size_t size) {
    if (size < 20) return false;  // Minimum header size

    size_t offset = 0;

    // Read header
    uint32_t version = readLE<uint32_t>(data + offset);
    offset += 4;

    if (version != SERIALIZATION_VERSION) return false;

    channelCount = readLE<uint32_t>(data + offset);
    offset += 4;

    if (channelCount == 0 || channelCount > 2) return false;

    sampleRate = readLE<uint32_t>(data + offset);
    offset += 4;

    duration = readLE<double>(data + offset);
    offset += 8;

    // Check remaining size
    size_t expectedDataSize = channelCount * 3 * BUCKET_COUNT * sizeof(float);
    if (size < offset + expectedDataSize) return false;

    // Read per-channel data
    for (uint32_t ch = 0; ch < channelCount; ch++) {
        min[ch].resize(BUCKET_COUNT);
        max[ch].resize(BUCKET_COUNT);
        rms[ch].resize(BUCKET_COUNT);

        for (size_t i = 0; i < BUCKET_COUNT; i++) {
            min[ch][i] = readLE<float>(data + offset);
            offset += 4;
        }
        for (size_t i = 0; i < BUCKET_COUNT; i++) {
            max[ch][i] = readLE<float>(data + offset);
            offset += 4;
        }
        for (size_t i = 0; i < BUCKET_COUNT; i++) {
            rms[ch][i] = readLE<float>(data + offset);
            offset += 4;
        }
    }

    return true;
}

std::vector<uint8_t> WaveformData::compress() const {
    std::vector<uint8_t> raw;
    serialize(raw);

    uLongf compressedSize = compressBound(static_cast<uLong>(raw.size()));
    std::vector<uint8_t> compressed(compressedSize + 4);

    // Store original size in first 4 bytes (little-endian)
    uint32_t originalSize = static_cast<uint32_t>(raw.size());
    compressed[0] = static_cast<uint8_t>(originalSize & 0xFF);
    compressed[1] = static_cast<uint8_t>((originalSize >> 8) & 0xFF);
    compressed[2] = static_cast<uint8_t>((originalSize >> 16) & 0xFF);
    compressed[3] = static_cast<uint8_t>((originalSize >> 24) & 0xFF);

    // Compress with default level (6) - good balance of speed vs size
    int result = compress2(
        compressed.data() + 4,
        &compressedSize,
        raw.data(),
        static_cast<uLong>(raw.size()),
        Z_DEFAULT_COMPRESSION
    );

    if (result != Z_OK) {
        return {};
    }

    compressed.resize(compressedSize + 4);
    return compressed;
}

std::optional<WaveformData> WaveformData::decompress(const uint8_t* data, size_t size) {
    if (size < 5) return std::nullopt;

    // Read original size (little-endian)
    uint32_t originalSize = static_cast<uint32_t>(data[0]) |
                           (static_cast<uint32_t>(data[1]) << 8) |
                           (static_cast<uint32_t>(data[2]) << 16) |
                           (static_cast<uint32_t>(data[3]) << 24);

    if (originalSize == 0 || originalSize > 1 * 1024 * 1024) {
        return std::nullopt;  // Sanity check: max 1MB (typical waveform ~49KB)
    }

    std::vector<uint8_t> decompressed(originalSize);
    uLongf destLen = originalSize;

    int result = uncompress(
        decompressed.data(),
        &destLen,
        data + 4,
        static_cast<uLong>(size - 4)
    );

    if (result != Z_OK || destLen != originalSize) {
        return std::nullopt;
    }

    WaveformData waveform;
    if (!waveform.deserialize(decompressed.data(), decompressed.size())) {
        return std::nullopt;
    }

    return waveform;
}
