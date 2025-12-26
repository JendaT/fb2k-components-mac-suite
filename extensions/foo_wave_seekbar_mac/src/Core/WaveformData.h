//
//  WaveformData.h
//  foo_wave_seekbar_mac
//
//  Core data structure for waveform peak data
//

#pragma once

#include <vector>
#include <cstdint>
#include <string>
#include <optional>

struct WaveformData {
    static const size_t BUCKET_COUNT = 2048;

    // Per-channel peak data (supports up to 2 channels)
    std::vector<float> min[2];   // Minimum sample value per bucket [-1.0, 0.0]
    std::vector<float> max[2];   // Maximum sample value per bucket [0.0, 1.0]
    std::vector<float> rms[2];   // RMS energy per bucket [0.0, 1.0]

    uint32_t channelCount = 0;   // 1 = mono, 2 = stereo
    uint32_t sampleRate = 0;     // Original sample rate
    double duration = 0.0;       // Track duration in seconds

    // Construction
    WaveformData() = default;
    void initialize(uint32_t channels, uint32_t rate, double dur);

    // Serialization (little-endian)
    void serialize(std::vector<uint8_t>& out) const;
    bool deserialize(const uint8_t* data, size_t size);

    // Compression (zlib)
    std::vector<uint8_t> compress() const;
    static std::optional<WaveformData> decompress(const uint8_t* data, size_t size);

    // Utility
    bool isValid() const;
    size_t memorySize() const;

    // Access helpers for rendering
    float getMinAt(uint32_t channel, double normalizedPosition) const;
    float getMaxAt(uint32_t channel, double normalizedPosition) const;
    float getRmsAt(uint32_t channel, double normalizedPosition) const;

private:
    // Serialization format version
    static const uint32_t SERIALIZATION_VERSION = 1;

    // Helper for little-endian serialization
    template<typename T>
    static void writeLE(std::vector<uint8_t>& out, T value);

    template<typename T>
    static T readLE(const uint8_t* data);
};
