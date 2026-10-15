//
//  TempoEstimatorTests.cpp
//  foo_jl_bpm_mac
//
//  Unit tests for the onset envelope and tempo estimator on synthetic drum
//  patterns. These check the mechanics (period, precision, range, input
//  handling); they say nothing about accuracy on real music.
//

#include "TestHarness.h"
#include "../src/Core/TempoEstimator.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>

using namespace bpm;

namespace {

// Seeded LCG so every run generates the same audio.
struct Rng {
    uint32_t s;
    double next() {  // -1..1
        s = s * 1664525u + 1013904223u;
        return static_cast<double>(s >> 8) / 8388608.0 - 1.0;
    }
};

struct Pattern {
    double bpm = 120.0;
    double sampleRate = 44100.0;
    double seconds = 30.0;
    unsigned channels = 2;
    double offbeatLevel = 0.0;  // weaker hit halfway between beats (eighth notes)
    double noiseLevel = 0.01;
    double hitLevel = 0.8;
};

// Interleaved audio: a decaying noise burst on every beat, optional weaker
// off-beat bursts, and a low noise floor.
std::vector<double> render(const Pattern &p) {
    const size_t frames = static_cast<size_t>(p.seconds * p.sampleRate);
    std::vector<double> mono(frames, 0.0);
    Rng rng{12345};
    for (size_t i = 0; i < frames; i++) mono[i] = p.noiseLevel * rng.next();

    auto addHit = [&](double atSeconds, double level, double decaySeconds) {
        const auto start = static_cast<size_t>(atSeconds * p.sampleRate);
        const auto length = static_cast<size_t>(decaySeconds * 6.0 * p.sampleRate);
        for (size_t i = 0; i < length && start + i < frames; i++) {
            const double t = static_cast<double>(i) / p.sampleRate;
            mono[start + i] += level * std::exp(-t / decaySeconds) * rng.next();
        }
    };

    const double period = 60.0 / p.bpm;
    for (double t = 0.05; t < p.seconds; t += period) {
        addHit(t, p.hitLevel, 0.02);
        if (p.offbeatLevel > 0.0) addHit(t + period / 2.0, p.offbeatLevel, 0.005);
    }

    std::vector<double> out(frames * p.channels);
    for (size_t i = 0; i < frames; i++) {
        for (unsigned c = 0; c < p.channels; c++) out[i * p.channels + c] = mono[i];
    }
    return out;
}

std::vector<float> envelopeOf(const Pattern &p, double *fpsOut, size_t chunkFrames = 4096) {
    const std::vector<double> audio = render(p);
    OnsetEnvelope env(p.sampleRate);
    const size_t frames = audio.size() / p.channels;
    for (size_t pos = 0; pos < frames; pos += chunkFrames) {
        const size_t count = std::min(chunkFrames, frames - pos);
        env.addInterleaved(audio.data() + pos * p.channels, count, p.channels);
    }
    if (fpsOut) *fpsOut = env.framesPerSecond();
    return env.values();
}

TempoResult estimate(const Pattern &p, const TempoOptions &options = {}) {
    double fps = 0.0;
    const std::vector<float> env = envelopeOf(p, &fps);
    return estimateTempo(env, fps, options);
}

void checkTempo(const Pattern &p, double expected, double tolerance) {
    char ctx[96];
    std::snprintf(ctx, sizeof(ctx), "bpm %.1f @ %.0f Hz", p.bpm, p.sampleRate);
    g_context = ctx;
    const TempoResult r = estimate(p);
    CHECK(r.valid, "result is valid");
    if (std::fabs(r.bpm - expected) > tolerance) {
        printf("  estimate %.3f, expected %.3f +/- %.2f\n", r.bpm, expected, tolerance);
    }
    CHECK(std::fabs(r.bpm - expected) <= tolerance, "estimate within tolerance");
    CHECK(r.strength >= kWeakPulseStrength, "steady beat is not reported as weak");
}

} // namespace

int main() {
    // Common tempos, beats only.
    for (double tempo : {72.0, 90.0, 100.0, 120.0, 128.0, 140.0, 150.0}) {
        Pattern p;
        p.bpm = tempo;
        checkTempo(p, tempo, 0.5);
    }

    // Fractional tempo resolves below one BPM.
    {
        Pattern p;
        p.bpm = 123.4;
        checkTempo(p, 123.4, 0.3);
    }

    // Other sample rates: the hop size adapts, the answer must not move.
    for (double rate : {22050.0, 48000.0, 96000.0}) {
        Pattern p;
        p.sampleRate = rate;
        checkTempo(p, 120.0, 0.5);
    }

    // Eighth-note off-beats put a periodicity at 180 BPM; the beat is 90.
    {
        Pattern p;
        p.bpm = 90.0;
        p.offbeatLevel = 0.3;
        checkTempo(p, 90.0, 0.5);
    }

    // 174 BPM sits where the prior barely separates 174 from 87; either is an
    // octave-correct answer and the user fixes it with Double/Halve.
    {
        g_context = "bpm 174 octave";
        Pattern p;
        p.bpm = 174.0;
        const TempoResult r = estimate(p);
        CHECK(r.valid, "result is valid");
        const bool octaveCorrect = std::fabs(r.bpm - 174.0) <= 0.7 || std::fabs(r.bpm - 87.0) <= 0.4;
        if (!octaveCorrect) printf("  estimate %.3f\n", r.bpm);
        CHECK(octaveCorrect, "174 or 87");
    }

    // The search range is honoured: 120 BPM limited to 40-100 gives 60.
    {
        g_context = "range 40-100";
        Pattern p;
        TempoOptions o;
        o.minBpm = 40.0;
        o.maxBpm = 100.0;
        const TempoResult r = estimate(p, o);
        CHECK(r.valid, "result is valid");
        if (std::fabs(r.bpm - 60.0) > 0.5) printf("  estimate %.3f\n", r.bpm);
        CHECK(std::fabs(r.bpm - 60.0) <= 0.5, "half tempo inside the range");
    }

    // Silence has no onsets: no result.
    {
        g_context = "silence";
        Pattern p;
        p.hitLevel = 0.0;
        p.noiseLevel = 0.0;
        CHECK(!estimate(p).valid, "silence is not valid");
    }

    // Noise has no pulse: valid or not, it must be reported as weak.
    {
        g_context = "noise";
        Pattern p;
        p.hitLevel = 0.0;
        p.noiseLevel = 0.3;
        const TempoResult r = estimate(p);
        if (r.valid && r.strength >= kWeakPulseStrength) printf("  strength %.3f\n", r.strength);
        CHECK(!r.valid || r.strength < kWeakPulseStrength, "noise is weak");
    }

    // Too short to judge.
    {
        g_context = "short";
        Pattern p;
        p.seconds = 4.0;
        CHECK(!estimate(p).valid, "4 seconds is not valid");
    }

    // Chunk boundaries do not change the envelope.
    {
        g_context = "chunking";
        Pattern p;
        p.seconds = 10.0;
        const std::vector<float> whole = envelopeOf(p, nullptr, 1u << 30);
        bool same = true;
        for (size_t chunk : {1u, 7u, 333u, 4096u}) {
            const std::vector<float> pieces = envelopeOf(p, nullptr, chunk);
            same = same && pieces == whole;
        }
        CHECK(!whole.empty(), "envelope has values");
        CHECK(same, "identical envelope for every chunk size");
    }

    // A mono file and the same audio on two channels give the same envelope.
    {
        g_context = "channels";
        Pattern mono;
        mono.seconds = 10.0;
        mono.channels = 1;
        Pattern stereo = mono;
        stereo.channels = 2;
        CHECK(envelopeOf(mono, nullptr) == envelopeOf(stereo, nullptr), "mono == duplicated stereo");
    }

    // Envelope rate lands in 150-300 frames per second at every common rate.
    {
        g_context = "frame rate";
        for (double rate : {8000.0, 22050.0, 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0}) {
            OnsetEnvelope env(rate);
            CHECK(env.framesPerSecond() >= 150.0 && env.framesPerSecond() < 300.0, "frame rate in range");
        }
    }

    TEST_MAIN_END();
}
