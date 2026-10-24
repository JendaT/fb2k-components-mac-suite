//
//  MeterEngine.h
//  foo_jl_levelmeter_mac
//
//  Runs every detector over the audio the player sends and turns the
//  results into one display snapshot per frame: bar ballistics (instant
//  attack, timed fall, peak hold), session maxima, clip latches, needle
//  readings, loudness and stereo figures. Pure C++, no SDK.
//

#pragma once

#include "Detectors.h"
#include "Loudness.h"
#include "StereoStats.h"
#include "TruePeak.h"

#include <cstddef>
#include <vector>

namespace meter {

struct EngineSettings {
    double rmsWindowSeconds = 0.3;
    bool   rmsSineReadsPeak = false;     // +3 dB so a sine's RMS equals its peak
    double peakFallDbPerSecond = 11.8;   // 20 dB in 1.7 s
    double peakHoldSeconds = 1.5;        // 0 = no hold marker
    bool   peakHoldForever = false;      // hold until reset
    bool   truePeak = true;              // bars and maxima use inter-sample peaks
    NeedleBallistics needle = NeedleBallistics::VU;
    double referenceDbfs = -18.0;        // sine RMS level that reads 0 on the needle
    double correlationSeconds = 0.3;
    double clipDbfs = 0.0;               // peaks above this latch the clip light
};

struct ChannelReading {
    float peakDb = kFloorDb;   // bar peak, with fall
    float holdDb = kFloorDb;   // held peak marker
    float rmsDb = kFloorDb;
    float maxDb = kFloorDb;    // highest peak since reset
    bool  clip = false;        // latched until reset
    float needleDb = kFloorDb; // needle reading relative to the reference (VU)
};

struct Snapshot {
    int channels = 2;                 // 1 = mono source (both readings equal)
    ChannelReading ch[2];
    double momentary;                 // LUFS, -inf before any audio
    double shortTerm;
    double integrated;
    double range = 0;                 // LU
    double measuredSeconds = 0;
    float truePeakMaxDb = kFloorDb;   // max of both channels over the loudness measurement
    float psrDb = 0;                  // recent peak (3 s) minus short-term
    float correlation = 0;
    float balanceDb = 0;
    bool  stereoSilent = true;
    bool  active = false;             // audio arrived in the last frame
    Snapshot();
};

class MeterEngine {
public:
    MeterEngine();

    void configure(const EngineSettings &s);
    const EngineSettings &settings() const { return _settings; }

    // Interleaved stereo frames; `channels` is the source's count (1 = mono,
    // in which case both values of each frame are the same).
    void process(const float *lr, size_t frames, double sampleRate, int channels);

    // No audio for `dt` seconds (paused, stopped): levels fall as if fed
    // silence, but the integrated loudness keeps its value.
    void idle(double dt);

    // Apply display ballistics over `dt` seconds and publish the snapshot.
    void advance(double dt);

    const Snapshot &snapshot() const { return _snap; }

    // Clear held maxima and clip lights (click on the meter).
    void resetPeaks();
    // Start a new loudness measurement (track change, or on request),
    // including the true peak max that goes with it.
    void resetLoudness();

private:
    void setSampleRate(double sr);
    void runDetectors(const float *lr, size_t frames);
    void notePsrPeak(float peak, size_t frames);

    EngineSettings _settings;
    double _sampleRate = 0;
    int _channels = 2;

    RmsWindow _rms[2];
    VuBallistics _vu[2];
    QuasiPeak _ppm[2];
    TruePeakDetector _tp[2];
    StereoStats _stereo;
    LoudnessMeter _loudness;

    // Peaks since the last advance()
    float _blockSample[2] = {0, 0};
    float _blockTrue[2] = {0, 0};
    bool  _gotAudio = false;
    double _holdTimer[2] = {0, 0};
    float _measurementPeakDb = kFloorDb;   // reset with the loudness measurement

    // Highest true (or sample) peak per 100 ms slot over the last 3 s.
    static constexpr int kPsrSlots = 30;
    float _psrSlot[kPsrSlots];
    int _psrPos = 0;
    size_t _psrFill = 0;

    std::vector<float> _silence;
    Snapshot _snap;
};

} // namespace meter
