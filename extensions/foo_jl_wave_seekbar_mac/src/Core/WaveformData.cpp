//
//  WaveformData.cpp
//  foo_wave_seekbar_mac
//

#include "WaveformData.h"
#include <zlib.h>
#include <algorithm>
#include <cstring>

namespace {

// Version 1 was the fixed 2048-bucket peak/RMS format; those blobs fail to
// decode and the track is simply analysed again.
const uint32_t kSerializationVersion = 2;
const uint32_t kMaxBlobSize = 64 * 1024 * 1024;

// Levels (mean squares) in 0.01 dB steps; INT16_MIN is silence.
int16_t encodeLevel(float meanSquare) {
    if (!(meanSquare > 1e-30f)) return INT16_MIN;
    const double q = std::round(1000.0 * std::log10((double)meanSquare));
    return (int16_t)std::clamp(q, -32767.0, 32767.0);
}

float decodeLevel(int16_t q) {
    return q == INT16_MIN ? 0.0f : (float)std::pow(10.0, q / 1000.0);
}

int16_t encodeSigned(float v) {
    return (int16_t)std::clamp(std::round((double)v * 32767.0), -32767.0, 32767.0);
}

uint16_t encodeUnsigned(float v) {
    return (uint16_t)std::clamp(std::round((double)v * 65535.0), 0.0, 65535.0);
}

class Writer {
public:
    std::vector<uint8_t> bytes;
    template <typename T> void put(T value) {
        uint8_t raw[sizeof(T)];
        std::memcpy(raw, &value, sizeof(T));   // little-endian host (arm64, x86_64)
        bytes.insert(bytes.end(), raw, raw + sizeof(T));
    }
};

class Reader {
public:
    Reader(const uint8_t* data, size_t size) : _data(data), _size(size) {}
    template <typename T> bool get(T& value) {
        if (_size - _offset < sizeof(T)) return false;
        std::memcpy(&value, _data + _offset, sizeof(T));
        _offset += sizeof(T);
        return true;
    }
    bool remaining(size_t bytes) const { return _size - _offset >= bytes; }
private:
    const uint8_t* _data;
    size_t _size;
    size_t _offset = 0;
};

} // namespace

bool WaveformData::isValid() const {
    if (channelCount < 1 || channelCount > 2) return false;
    if (sampleRate == 0 || !(duration > 0.0) || blockFrames == 0 || hopFrames == 0) return false;
    const size_t blocks = blockCount(), hops = hopCount();
    if (blocks == 0 || hops == 0) return false;
    for (uint32_t ch = 0; ch < channelCount; ++ch) {
        if (blockMin[ch].size() != blocks || blockMax[ch].size() != blocks || blockRms[ch].size() != blocks) return false;
        if (hopKms[ch].size() != hops || hopMs[ch].size() != hops) return false;
    }
    if (channelCount == 2 && hopLR.size() != hops) return false;
    for (const auto& band : hopBand) {
        if (band.size() != hops) return false;
    }
    return true;
}

size_t WaveformData::memorySize() const {
    size_t size = sizeof(*this) + hopLR.capacity() * sizeof(float) + clipRunFrames.capacity() * sizeof(uint64_t);
    for (int ch = 0; ch < 2; ++ch) {
        size += (blockMin[ch].capacity() + blockMax[ch].capacity() + blockRms[ch].capacity()
                 + hopKms[ch].capacity() + hopMs[ch].capacity()) * sizeof(float);
    }
    for (const auto& band : hopBand) size += band.capacity() * sizeof(float);
    return size;
}

std::vector<uint8_t> WaveformData::compress() const {
    if (!isValid()) return {};

    Writer w;
    w.put(kSerializationVersion);
    w.put(channelCount);
    w.put(sampleRate);
    w.put(duration);
    w.put(blockFrames);
    w.put(hopFrames);
    w.put((uint32_t)blockCount());
    w.put((uint32_t)hopCount());
    w.put((uint32_t)clipRunFrames.size());
    w.put(summary.integrated);
    w.put(summary.range);
    w.put(summary.truePeak);
    w.put(summary.samplePeak);
    w.put(summary.clipRuns);

    for (uint32_t ch = 0; ch < channelCount; ++ch) {
        for (float v : blockMin[ch]) w.put(encodeSigned(v));
        for (float v : blockMax[ch]) w.put(encodeSigned(v));
        for (float v : blockRms[ch]) w.put(encodeUnsigned(v));
    }
    for (uint32_t ch = 0; ch < channelCount; ++ch) {
        for (float v : hopKms[ch]) w.put(encodeLevel(v));
        for (float v : hopMs[ch]) w.put(encodeLevel(v));
    }
    // L*R as a correlation coefficient, which quantizes evenly
    if (channelCount == 2) {
        for (size_t i = 0; i < hopCount(); ++i) {
            const float norm = std::sqrt(hopMs[0][i] * hopMs[1][i]);
            w.put(encodeSigned(norm > 0.0f ? std::clamp(hopLR[i] / norm, -1.0f, 1.0f) : 0.0f));
        }
    }
    for (const auto& band : hopBand) {
        for (float v : band) w.put(encodeLevel(v));
    }
    for (uint64_t frame : clipRunFrames) w.put(frame);

    // Original size, then the zlib stream
    const std::vector<uint8_t>& raw = w.bytes;
    if (raw.size() > kMaxBlobSize) return {};
    uLongf compressedSize = compressBound((uLong)raw.size());
    std::vector<uint8_t> out(compressedSize + 4);
    const uint32_t rawSize = (uint32_t)raw.size();
    std::memcpy(out.data(), &rawSize, 4);
    if (compress2(out.data() + 4, &compressedSize, raw.data(), (uLong)raw.size(), Z_DEFAULT_COMPRESSION) != Z_OK) {
        return {};
    }
    out.resize(compressedSize + 4);
    return out;
}

std::optional<WaveformData> WaveformData::decompress(const uint8_t* data, size_t size) {
    if (size < 5) return std::nullopt;
    uint32_t rawSize;
    std::memcpy(&rawSize, data, 4);
    if (rawSize == 0 || rawSize > kMaxBlobSize) return std::nullopt;

    std::vector<uint8_t> raw(rawSize);
    uLongf destLen = rawSize;
    if (uncompress(raw.data(), &destLen, data + 4, (uLong)(size - 4)) != Z_OK || destLen != rawSize) {
        return std::nullopt;
    }

    Reader r(raw.data(), raw.size());
    WaveformData w;
    uint32_t version = 0, blocks = 0, hops = 0, clips = 0;
    if (!r.get(version) || version != kSerializationVersion) return std::nullopt;
    if (!r.get(w.channelCount) || !r.get(w.sampleRate) || !r.get(w.duration) ||
        !r.get(w.blockFrames) || !r.get(w.hopFrames) ||
        !r.get(blocks) || !r.get(hops) || !r.get(clips) ||
        !r.get(w.summary.integrated) || !r.get(w.summary.range) || !r.get(w.summary.truePeak) ||
        !r.get(w.summary.samplePeak) || !r.get(w.summary.clipRuns)) {
        return std::nullopt;
    }
    if (w.channelCount < 1 || w.channelCount > 2) return std::nullopt;

    const size_t chans = w.channelCount;
    const size_t expected = chans * blocks * 6 + chans * hops * 4 + (chans == 2 ? hops * 2 : 0)
                          + hops * 6 + (size_t)clips * 8;
    if (!r.remaining(expected)) return std::nullopt;

    int16_t s16;
    uint16_t u16;
    for (size_t ch = 0; ch < chans; ++ch) {
        for (auto* v : { &w.blockMin[ch], &w.blockMax[ch] }) {
            v->resize(blocks);
            for (auto& x : *v) { r.get(s16); x = s16 / 32767.0f; }
        }
        w.blockRms[ch].resize(blocks);
        for (auto& x : w.blockRms[ch]) { r.get(u16); x = u16 / 65535.0f; }
    }
    for (size_t ch = 0; ch < chans; ++ch) {
        for (auto* v : { &w.hopKms[ch], &w.hopMs[ch] }) {
            v->resize(hops);
            for (auto& x : *v) { r.get(s16); x = decodeLevel(s16); }
        }
    }
    if (chans == 2) {
        w.hopLR.resize(hops);
        for (size_t i = 0; i < hops; ++i) {
            r.get(s16);
            w.hopLR[i] = s16 / 32767.0f * std::sqrt(w.hopMs[0][i] * w.hopMs[1][i]);
        }
    }
    for (auto& band : w.hopBand) {
        band.resize(hops);
        for (auto& x : band) { r.get(s16); x = decodeLevel(s16); }
    }
    w.clipRunFrames.resize(clips);
    for (auto& frame : w.clipRunFrames) r.get(frame);

    if (!w.isValid()) return std::nullopt;
    return w;
}
