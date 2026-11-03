//
//  ResampleLowpassTests.cpp
//  foo_jl_bpm_mac
//
//  The soxr-like top-band roll-off: its response, alignment and streaming.
//

#include "TestHarness.h"
#include "../src/Core/ResampleLowpass.h"

#include <cmath>
#include <vector>

using namespace bpm;

namespace {

std::vector<float> runAll(const std::vector<float> &x, size_t chunk, int factor = 1) {
    ResampleLowpass f(factor);
    std::vector<float> out;
    for (size_t i = 0; i < x.size(); i += chunk) f.process(x.data() + i, std::min(chunk, x.size() - i), out);
    f.finish(out);
    return out;
}

// Gain in dB of a sine at `hz` (at 22050 * factor) through the filter,
// steady state in the middle; at factor > 1 a sine above 11.025 kHz comes
// out aliased, its level the alias rejection
double gainDb(double hz, int factor = 1) {
    const double rate = 22050.0 * factor;
    std::vector<float> x(static_cast<size_t>(rate));
    for (size_t i = 0; i < x.size(); i++) x[i] = static_cast<float>(std::sin(2 * M_PI * hz * i / rate));
    const std::vector<float> y = runAll(x, x.size(), factor);
    double in = 0.0, out = 0.0;
    for (size_t i = 5000; i < 17000; i++) {
        in += double(x[i * factor]) * x[i * factor];
        out += double(y[i]) * y[i];
    }
    return 10.0 * std::log10(std::max(out, 1e-30) / in);
}

void testResponse() {
    g_context = "response";
    ResampleLowpass f;
    CHECK_EQ(f.taps().size(), 181, "181 taps");
    double sum = 0.0;
    for (double t : f.taps()) sum += t;
    CHECK(std::fabs(sum - 1.0) < 1e-12, "unity gain at DC");
    printf("    gain: 1 kHz %.4f dB, 9 kHz %.4f dB, 10 kHz %.4f dB, 10.55 kHz %.1f dB, 10.9 kHz %.1f dB, 11 kHz %.1f dB\n",
           gainDb(1000), gainDb(9000), gainDb(10000), gainDb(10545), gainDb(10900), gainDb(11000));
    CHECK(std::fabs(gainDb(1000)) < 0.001, "flat at 1 kHz");
    CHECK(std::fabs(gainDb(10000)) < 0.01, "flat to 10 kHz (soxr HQ's passband ends at 10.07 kHz)");
    CHECK(gainDb(10545) < -5.0 && gainDb(10545) > -7.0, "about -6 dB halfway through the transition");
    // The transition runs to Nyquist (11.025 kHz), as soxr's does
    CHECK(gainDb(10800) < -25.0 && gainDb(10900) < -45.0 && gainDb(11000) < -90.0, "falling through the transition");
}

void testDecimation() {
    g_context = "decimation";
    for (int factor : { 2, 4 }) {
        ResampleLowpass f(factor);
        CHECK_EQ((f.taps().size() - 1) % (2 * factor), 0, "delay of a whole number of outputs");
        printf("    factor %d (%zu taps): 1 kHz %.4f dB, 10 kHz %.4f dB, 10.55 kHz %.1f dB; alias of 12 kHz %.1f dB, of 15 kHz %.1f dB\n", factor,
               f.taps().size(), gainDb(1000, factor), gainDb(10000, factor), gainDb(10545, factor), gainDb(12000, factor), gainDb(15000, factor));
        CHECK(std::fabs(gainDb(1000, factor)) < 0.001, "flat at 1 kHz");
        CHECK(std::fabs(gainDb(10000, factor)) < 0.01, "flat to 10 kHz");
        CHECK(gainDb(12000, factor) < -100.0 && gainDb(15000, factor) < -100.0, "aliases over 100 dB down");

        std::vector<float> x(20000, 0.0f);
        x[6000] = 1.0f;
        const std::vector<float> y = runAll(x, x.size(), factor);
        CHECK_EQ(y.size(), (x.size() + factor - 1) / factor, "one output per factor inputs");
        size_t peak = 0;
        for (size_t i = 0; i < y.size(); i++) if (std::fabs(y[i]) > std::fabs(y[peak])) peak = i;
        CHECK_EQ(peak, 6000 / factor, "an impulse lands on input index / factor");
        for (size_t chunk : { 1, 3, 1000 }) {
            const std::vector<float> z = runAll(x, chunk, factor);
            bool same = z.size() == y.size();
            for (size_t i = 0; same && i < z.size(); i++) same = std::fabs(z[i] - y[i]) < 1e-7f;
            CHECK(same, "the same whatever the chunk size");
        }
    }
}

void testAlignmentAndStreaming() {
    g_context = "alignment";
    std::vector<float> x(10000, 0.0f);
    x[3000] = 1.0f;
    const std::vector<float> y = runAll(x, x.size());
    CHECK_EQ(y.size(), x.size(), "as many samples out as in");
    size_t peak = 0;
    for (size_t i = 0; i < y.size(); i++) if (std::fabs(y[i]) > std::fabs(y[peak])) peak = i;
    CHECK_EQ(peak, 3000, "no delay: an impulse stays where it was");
    for (size_t chunk : { 1, 90, 181, 1000 }) {
        const std::vector<float> z = runAll(x, chunk);
        bool same = z.size() == y.size();
        for (size_t i = 0; same && i < z.size(); i++) same = std::fabs(z[i] - y[i]) < 1e-7f;
        CHECK(same, "the same whatever the chunk size");
    }
    std::vector<float> few(50, 0.5f);
    CHECK_EQ(runAll(few, 50).size(), 50, "shorter than the filter: still as many out as in");
}

} // namespace

int main() {
    testResponse();
    testAlignmentAndStreaming();
    testDecimation();
    TEST_MAIN_END();
}
