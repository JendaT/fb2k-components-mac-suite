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
    uint32_t channelCount = 0;      // 1 = mono, 2 = stereo (first two channels of anything wider)
    uint32_t sampleRate = 0;
    double duration = 0.0;          // seconds

    // Fine blocks (blockFrames each, the last one may be shorter): drawing.
    uint32_t blockFrames = 0;
    std::vector<float> blockMin[2];     // sample minimum, -1..0
    std::vector<float> blockMax[2];     // sample maximum, 0..1
    std::vector<float> blockRms[2];     // RMS amplitude, 0..1

    // Hops (100 ms each, the last one may be shorter): loudness gates,
    // readout and band split. Mean squares, i.e. power per frame.
    uint32_t hopFrames = 0;
    std::vector<float> hopKms[2];       // K-weighted (BS.1770) mean square per channel
    std::vector<float> hopMs[2];        // plain mean square per channel
    std::vector<float> hopLR;           // mean of L*R (correlation numerator); empty for mono
    std::vector<float> hopBand[3];      // Lo / Mid / Hi mean square, channels summed

    // Start frame of each clip run (3+ consecutive samples at full scale on
    // any channel; overlapping runs on several channels count once).
    std::vector<uint64_t> clipRunFrames;

    LoudnessSummary summary;

    size_t blockCount() const { return blockMin[0].size(); }
    size_t hopCount() const { return hopKms[0].size(); }

    bool isValid() const;
    size_t memorySize() const;

    // Cache blob: zlib-compressed, levels quantized to 0.01 dB steps and
    // samples to 16 bits.
    std::vector<uint8_t> compress() const;
    static std::optional<WaveformData> decompress(const uint8_t* data, size_t size);
};
