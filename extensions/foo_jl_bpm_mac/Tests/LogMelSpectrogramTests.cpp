//
//  LogMelSpectrogramTests.cpp
//  foo_jl_bpm_mac
//
//  The front end against torchaudio's output for the same signal
//  (Tests/fixtures/logmel_reference.bin, from
//  Scripts/beat_this/make_logmel_reference.py), whole and streamed.
//

#include "TestHarness.h"
#include "../src/Core/LogMelSpectrogram.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using namespace bpm;

namespace {

// The generator's formula, sample for sample
std::vector<float> testSignal() {
    const size_t n = 55125;
    std::vector<float> x(n);
    for (size_t i = 0; i < n; i++) {
        const double t = static_cast<double>(i) / 22050.0;
        double v = 0.3 * std::sin(2 * M_PI * 110 * t) * (0.6 + 0.4 * std::sin(2 * M_PI * 2 * t));
        v += 0.2 * std::sin(2 * M_PI * 440 * t + 0.5);
        v += 0.1 * std::sin(2 * M_PI * 3000 * t);
        v += 0.05 * std::sin(2 * M_PI * (200 + 2000 * t) * t);
        for (int k = 0; k < 5; k++) {
            const double d = static_cast<double>(i) - k * 11025.0;
            if (d >= 0 && d < 2000) v += 0.8 * std::exp(-d / 50.0) * std::sin(2 * M_PI * 1500 * t);
        }
        x[i] = static_cast<float>(v);
    }
    return x;
}

bool loadReference(std::vector<float> &values, uint32_t &frames, uint32_t &bands) {
    std::string path = __FILE__;
    path = path.substr(0, path.find_last_of('/')) + "/fixtures/logmel_reference.bin";
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) return false;
    uint32_t shape[2] = {};
    const bool ok = fread(shape, sizeof shape, 1, f) == 1;
    frames = shape[0];
    bands = shape[1];
    values.resize(static_cast<size_t>(frames) * bands);
    const bool data = ok && fread(values.data(), 4, values.size(), f) == values.size();
    fclose(f);
    return data;
}

std::vector<float> run(const std::vector<float> &x, size_t chunk) {
    LogMelSpectrogram mel;
    std::vector<float> out;
    for (size_t i = 0; i < x.size(); i += chunk) {
        mel.add(x.data() + i, std::min(chunk, x.size() - i));
        const std::vector<float> got = mel.take();
        out.insert(out.end(), got.begin(), got.end());
    }
    mel.finish();
    const std::vector<float> rest = mel.take();
    out.insert(out.end(), rest.begin(), rest.end());
    return out;
}

double maxDiff(const std::vector<float> &a, const std::vector<float> &b) {
    double worst = 0.0;
    for (size_t i = 0; i < std::min(a.size(), b.size()); i++) worst = std::max(worst, std::fabs(double(a[i]) - b[i]));
    return worst;
}

void testAgainstTorchaudio() {
    g_context = "torchaudio parity";
    std::vector<float> reference;
    uint32_t frames = 0, bands = 0;
    CHECK(loadReference(reference, frames, bands), "fixture loads");
    CHECK_EQ(bands, kMelBands, "128 bands");
    CHECK_EQ(frames, 1 + 55125 / kMelHop, "centred frames: 1 + n / hop");

    const std::vector<float> whole = run(testSignal(), 55125);
    CHECK_EQ(whole.size(), reference.size(), "same frame count");
    const double diff = maxDiff(whole, reference);
    printf("    max abs diff vs torchaudio: %.2e\n", diff);
    CHECK(diff < 1e-4, "within 1e-4 of torchaudio");

    // The reflected ends: first two and last frames
    std::vector<float> ends(whole.begin(), whole.begin() + 2 * kMelBands);
    ends.insert(ends.end(), whole.end() - kMelBands, whole.end());
    std::vector<float> refEnds(reference.begin(), reference.begin() + 2 * kMelBands);
    refEnds.insert(refEnds.end(), reference.end() - kMelBands, reference.end());
    CHECK(maxDiff(ends, refEnds) < 1e-4, "reflected ends match");
}

void testStreaming() {
    g_context = "streaming";
    const std::vector<float> x = testSignal();
    const std::vector<float> whole = run(x, x.size());
    for (size_t chunk : { 1, 100, 441, 512, 1000, 4096 }) {
        const std::vector<float> streamed = run(x, chunk);
        CHECK_EQ(streamed.size(), whole.size(), "same frames whatever the chunk size");
        CHECK(maxDiff(streamed, whole) == 0.0, "identical values whatever the chunk size");
    }
}

void testShortAndSilent() {
    g_context = "short";
    LogMelSpectrogram mel;
    std::vector<float> x(400, 0.1f);
    mel.add(x.data(), x.size());
    mel.finish();
    CHECK_EQ(mel.framesProduced(), 0, "under half a window: no frames");

    LogMelSpectrogram silent;
    std::vector<float> zeros(22050, 0.0f);
    silent.add(zeros.data(), zeros.size());
    silent.finish();
    const std::vector<float> out = silent.take();
    CHECK_EQ(out.size() / kMelBands, 1 + 22050 / kMelHop, "one second: 51 frames");
    CHECK(maxDiff(out, std::vector<float>(out.size(), 0.0f)) == 0.0, "silence is log1p(0) = 0");
}

} // namespace

int main() {
    testAgainstTorchaudio();
    testStreaming();
    testShortAndSilent();
    TEST_MAIN_END();
}
