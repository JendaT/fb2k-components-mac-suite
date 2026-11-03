//
//  LogMelSpectrogram.h
//  foo_jl_bpm_mac
//
//  The Beat This! network's input, computed as upstream does it with
//  torchaudio (MelSpectrogram + log1p) so the network sees what it was
//  trained on: mono 22.05 kHz, STFT of 1024 points every 441 samples (50
//  frames per second) with a periodic Hann window, frames centred on their
//  hop (reflect padding at both ends), magnitudes over sqrt(1024), 128 mel
//  bands on the Slaney scale from 30 Hz to 11 kHz (triangles not area
//  normalised), then log(1 + 1000 x). Plain C++ on Accelerate, unit tested
//  against torchaudio's output (Tests/fixtures/logmel_reference.bin).
//
//  Streams: samples go in as they are decoded and frames come out as soon as
//  their window is complete, so a track of any length never sits in memory.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <vector>

namespace bpm {

constexpr double kMelSampleRate = 22050.0;
constexpr size_t kMelFFT = 1024;
constexpr size_t kMelHop = 441;
constexpr size_t kMelBands = 128;

class LogMelSpectrogram {
public:
    LogMelSpectrogram();
    ~LogMelSpectrogram();
    LogMelSpectrogram(const LogMelSpectrogram &) = delete;
    LogMelSpectrogram &operator=(const LogMelSpectrogram &) = delete;

    // Mono samples at kMelSampleRate
    void add(const float *samples, size_t count);
    // After the last sample: the frames whose window runs past the end. A
    // piece shorter than half a window yields no frames at all.
    void finish();

    // Frames completed and not yet taken, kMelBands values each, oldest
    // first; take() hands them over and forgets them
    size_t pendingFrames() const;
    std::vector<float> take();
    // Every frame produced so far, taken or not
    uint64_t framesProduced() const;

private:
    struct Impl;
    std::unique_ptr<Impl> m;
};

} // namespace bpm
