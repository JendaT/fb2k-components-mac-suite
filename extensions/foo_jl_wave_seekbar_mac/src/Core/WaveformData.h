//
//  WaveformData.h
//  foo_wave_seekbar_mac
//
//  Per-track analysis, cached: block arrays at two fixed resolutions plus a
//  loudness summary. Per-column values are aggregated from these at draw time
//  (ColumnAggregator), so a resize never re-decodes. Pure C++ (zlib only).
//

#pragma once

#include <vector>
#include <cstdint>
#include <cmath>
#include <optional>

struct LoudnessSummary {
    float integrated = -INFINITY;   // LUFS, BS.1770-4 gating
    float range = 0.0f;             // LRA in LU, EBU Tech 3342
    float truePeak = -INFINITY;     // dBTP, 4x oversampled
    float samplePeak = -INFINITY;   // dBFS
    uint32_t clipRuns = 0;          // runs of 3+ samples at full scale

    // Peak-to-loudness ratio, TP - I
    float plr() const { return truePeak - integrated; }
};

struct WaveformData {
    uint32_t channelCount = 0;      // drawn: 1 = mono, 2 = stereo (first two channels of anything wider)
    uint32_t sampleRate = 0;
    double duration = 0.0;          // seconds

    // Fine blocks (blockFrames each, the last one may be shorter): drawing.
    uint32_t blockFrames = 0;
    std::vector<float> blockMin[2];     // sample minimum, -1..0 (below -1 past full scale)
    std::vector<float> blockMax[2];     // sample maximum, 0..1 (above 1 past full scale)
    std::vector<float> blockRms[2];     // RMS amplitude, 0..1

    // Hops (100 ms each, the last one may be shorter): loudness gates,
    // readout and band split. Mean squares, i.e. power per frame.
    uint32_t hopFrames = 0;
    std::vector<float> hopKms[2];       // K-weighted (BS.1770) mean square per channel
    std::vector<float> hopKmsSum;       // the same over all source channels with BS.1770 weights
                                        // (surround 1.41, no LFE): gates and LUFS readout
    std::vector<float> hopMs[2];        // plain mean square per channel
    std::vector<float> hopLR;           // mean of L*R (correlation numerator); empty for mono
    std::vector<float> hopBand[3];      // Lo / Mid / Hi mean square, drawn channels summed

    // Start frame of each clip run (3+ consecutive samples at full scale on
    // any source channel; overlapping runs on several channels count once).
    std::vector<uint64_t> clipRunFrames;

    LoudnessSummary summary;

    size_t blockCount() const { return blockMin[0].size(); }
    size_t hopCount() const { return hopKms[0].size(); }

    bool isValid() const;
    size_t memorySize() const;

    // Cache blob: zlib-compressed, levels quantized to 0.01 dB steps and
    // samples to 16 bits over +-2 (+6 dBFS).
    std::vector<uint8_t> compress() const;
    static std::optional<WaveformData> decompress(const uint8_t* data, size_t size);
};

// Fine blocks for deep zoom (the "fine detail" option), gathered in the same
// pass as the WaveformData: sample minimum, maximum and RMS of the drawn
// channels, a divisor of its block long. Kept as the cache stores them, 16
// bits each, since a long track has up to kMaxDetailBlocks of them.
struct WaveformDetail {
    static constexpr double kSampleRange = 2.0;     // as WaveformData's cache: peaks past full scale survive

    uint32_t channelCount = 0;
    uint32_t sampleRate = 0;
    uint32_t blockFrames = 0;
    uint64_t frames = 0;                            // analysed audio
    std::vector<int16_t> blockMin[2], blockMax[2];  // +-32767 is +-kSampleRange
    std::vector<uint16_t> blockRms[2];              // 65535 is kSampleRange

    size_t blockCount() const { return blockMin[0].size(); }
    float minAt(uint32_t ch, size_t b) const { return (float)(blockMin[ch][b] * (kSampleRange / 32767.0)); }
    float maxAt(uint32_t ch, size_t b) const { return (float)(blockMax[ch][b] * (kSampleRange / 32767.0)); }
    float rmsAt(uint32_t ch, size_t b) const { return (float)(blockRms[ch][b] * (kSampleRange / 65535.0)); }
    static int16_t encodeSample(float v);
    static uint16_t encodeRms(float v);

    bool isValid() const;
    // Analysed with `data`: the same audio, in blocks finer than its own
    bool matches(const WaveformData& data) const;
    size_t memorySize() const;

    std::vector<uint8_t> compress() const;
    static std::optional<WaveformDetail> decompress(const uint8_t* data, size_t size);
};
