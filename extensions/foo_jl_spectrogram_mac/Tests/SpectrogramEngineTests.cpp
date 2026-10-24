//
//  SpectrogramEngineTests.cpp
//  foo_jl_spectrogram_mac
//
//  Unit tests for the column renderer: axis mapping, dBFS calibration,
//  multi-resolution windows, and level mapping, driven by synthetic tones.
//  Standalone: no SDK, no Xcode.
//

#include "TestHarness.h"
#include "../src/Core/SpectrogramEngine.h"
#include <vector>

namespace {

const int kRows = 600;

std::vector<float> tone(int count, double hz, double sampleRate, double amplitude) {
    std::vector<float> x((size_t)count);
    for (int n = 0; n < count; ++n) {
        x[(size_t)n] = (float)(amplitude * std::sin(2.0 * M_PI * hz * n / sampleRate));
    }
    return x;
}

struct Peak {
    int   row = 0;
    float level = 0.0f;
};

Peak peakOf(const std::vector<float>& column) {
    Peak p;
    for (size_t r = 0; r < column.size(); ++r) {
        if (column[r] > p.level) { p.level = column[r]; p.row = (int)r; }
    }
    return p;
}

// Render one column of a steady tone with the given settings.
std::vector<float> render(const SpectrogramEngine::Settings& s, double hz, double amplitude,
                          double sampleRate = 44100.0) {
    SpectrogramEngine engine;
    engine.configure(s);
    engine.setRows(kRows);
    engine.setSampleRate(sampleRate);
    std::vector<float> column((size_t)kRows, -1.0f);
    engine.renderColumn(tone(engine.windowLength(), hz, sampleRate, amplitude).data(), column.data());
    return column;
}

double rowHz(const SpectrogramEngine::Settings& s, int row) {
    return SpectrogramEngine::hzForFraction(s.scale, s.minHz, s.maxHz, 1.0 - (row + 0.5) / kRows);
}

void testAxisMapping() {
    const int scales[] = {SpectrogramEngine::ScaleLog, SpectrogramEngine::ScaleMel, SpectrogramEngine::ScaleLinear};
    for (int scale : scales) {
        g_context = "axis scale " + std::to_string(scale);
        CHECK_FLOAT_EQ(SpectrogramEngine::fractionForHz(scale, 20, 20000, 20), 0.0, "minHz at 0");
        CHECK_FLOAT_EQ(SpectrogramEngine::fractionForHz(scale, 20, 20000, 20000), 1.0, "maxHz at 1");
        for (double t : {0.1, 0.37, 0.5, 0.92}) {
            const double hz = SpectrogramEngine::hzForFraction(scale, 20, 20000, t);
            CHECK_FLOAT_EQ(SpectrogramEngine::fractionForHz(scale, 20, 20000, hz), t, "round trip");
        }
    }
    g_context = "axis";
    // Log scale: each decade takes a third of 20 Hz..20 kHz.
    CHECK_FLOAT_EQ(SpectrogramEngine::fractionForHz(SpectrogramEngine::ScaleLog, 20, 20000, 200), 1.0 / 3.0, "log decade");
    CHECK_FLOAT_EQ(SpectrogramEngine::fractionForHz(SpectrogramEngine::ScaleLinear, 0, 20000, 5000), 0.25, "linear quarter");
}

void testWindowLength() {
    g_context = "window length";
    SpectrogramEngine engine;
    SpectrogramEngine::Settings s;
    engine.configure(s);
    engine.setRows(kRows);
    CHECK_EQ(engine.windowLength(), 16384, "multi-res reads the 4x window");
    engine.setSampleRate(96000.0);
    CHECK_EQ(engine.windowLength(), 32768, "doubled at 96 kHz");
    engine.setSampleRate(192000.0);
    CHECK_EQ(engine.windowLength(), 65536, "quadrupled at 192 kHz");

    s.multiRes = false;
    engine.configure(s);
    engine.setSampleRate(48000.0);
    CHECK_EQ(engine.windowLength(), 4096, "single resolution reads the base window");

    s.fftSize = 3000;  // not a power of two
    engine.configure(s);
    CHECK_EQ(engine.windowLength(), 4096, "size rounds up to a power of two");
}

// A full-scale sine must read near the top of a 0 dB..-90 dB window at the
// row of its own frequency, whichever FFT stage that row uses.
void testCalibration() {
    for (bool multi : {true, false}) {
        for (int window : {SpectrogramEngine::WindowHann, SpectrogramEngine::WindowBlackmanHarris}) {
            SpectrogramEngine::Settings s;
            s.multiRes = multi;
            s.window = window;
            for (double hz : {40.0, 110.0, 290.0, 1000.0, 2900.0, 9000.0, 15000.0}) {
                g_context = std::string(multi ? "multi" : "single") + " window " + std::to_string(window) +
                            " " + std::to_string((int)hz) + " Hz";
                const Peak p = peakOf(render(s, hz, 1.0));
                const double db = (p.level - 1.0) * s.rangeDb;
                CHECK(db > -3.0 && db <= 0.01, "full-scale sine reads within 3 dB of 0 dBFS");
                // Within 3%, or a bin and a half of the base window at the low end.
                const double err = std::fabs(rowHz(s, p.row) - hz);
                CHECK(err < std::max(hz * 0.03, multi ? 4.0 : 16.0), "peak sits at the tone's frequency");
            }
        }
    }
}

void testLevelMapping() {
    g_context = "level mapping";
    SpectrogramEngine::Settings s;

    // -45 dBFS is halfway down a 0..-90 dB window.
    const double amp45 = std::pow(10.0, -45.0 / 20.0);
    Peak p = peakOf(render(s, 1000.0, amp45));
    CHECK(std::fabs(p.level - 0.5f) < 0.03f, "-45 dB tone at mid level");

    // Lowering the top level by 20 dB lifts the same tone by 20 dB of range.
    s.topDb = -20.0f;
    p = peakOf(render(s, 1000.0, amp45));
    CHECK(std::fabs(p.level - (0.5f + 20.0f / 90.0f)) < 0.03f, "top level shifts the window");

    // Louder than the top clamps at 1.
    s.topDb = -40.0f;
    p = peakOf(render(s, 1000.0, 1.0));
    CHECK_FLOAT_EQ(p.level, 1.0, "clamped at the top");

    g_context = "silence";
    SpectrogramEngine::Settings quiet;
    const std::vector<float> column = render(quiet, 1000.0, 0.0);
    CHECK_FLOAT_EQ(peakOf(column).level, 0.0, "silence reads the floor");
    bool written = true;
    for (float v : column) written = written && v == 0.0f;
    CHECK(written, "every row is written");
}

void testSlope() {
    g_context = "slope";
    SpectrogramEngine::Settings s;
    const double amp = std::pow(10.0, -40.0 / 20.0);
    const float flat = peakOf(render(s, 4000.0, amp)).level;
    s.slopeDb = 3.0f;
    const float tilted = peakOf(render(s, 4000.0, amp)).level;
    // Two octaves above the 1 kHz pivot at 3 dB/octave: +6 dB.
    CHECK(std::fabs((tilted - flat) * s.rangeDb - 6.0f) < 0.5f, "+6 dB two octaves above 1 kHz");

    const float pivotFlat = peakOf(render(SpectrogramEngine::Settings{}, 1000.0, amp)).level;
    const float pivotTilted = peakOf(render(s, 1000.0, amp)).level;
    CHECK(std::fabs(pivotTilted - pivotFlat) * s.rangeDb < 0.3f, "no change at the pivot");
}

void testNyquist() {
    g_context = "nyquist";
    SpectrogramEngine::Settings s;
    s.maxHz = 40000.0;  // axis reaches past 22.05 kHz at 44.1 kHz
    const std::vector<float> column = render(s, 15000.0, 1.0);
    bool blank = true;
    for (int r = 0; r < kRows; ++r) {
        if (rowHz(s, r) > 22050.0 && column[(size_t)r] != 0.0f) blank = false;
    }
    CHECK(blank, "rows above Nyquist stay at the floor");
    CHECK(peakOf(column).level > 0.9f, "the tone below Nyquist still shows");
}

// The point of multi-resolution: a bass tone covers fewer rows.
void testBassResolution() {
    g_context = "bass resolution";
    auto width = [](bool multi) {
        SpectrogramEngine::Settings s;
        s.multiRes = multi;
        const std::vector<float> column = render(s, 50.0, 0.5);
        const float cut = peakOf(column).level - 20.0f / s.rangeDb;
        int rows = 0;
        for (float v : column) rows += v > cut ? 1 : 0;
        return rows;
    };
    const int multi = width(true), single = width(false);
    CHECK(multi * 2 < single, "50 Hz line at least twice as thin with the long window");
}

void testRows() {
    g_context = "rows";
    SpectrogramEngine engine;
    engine.configure(SpectrogramEngine::Settings{});
    engine.setRows(0);
    const std::vector<float> samples = tone(engine.windowLength(), 1000.0, 44100.0, 1.0);
    float guard = 7.0f;
    engine.renderColumn(samples.data(), &guard);
    CHECK_FLOAT_EQ(guard, 7.0, "zero rows writes nothing");

    // Changing the row count re-maps the same tone to the same frequency.
    for (int rows : {37, 240, 1500}) {
        engine.setRows(rows);
        CHECK_EQ(engine.rows(), rows, "row count applied");
        std::vector<float> column((size_t)rows);
        engine.renderColumn(samples.data(), column.data());
        const Peak p = peakOf(column);
        const double hz = SpectrogramEngine::hzForFraction(SpectrogramEngine::ScaleLog, 20, 20000,
                                                           1.0 - (p.row + 0.5) / rows);
        CHECK(std::fabs(hz - 1000.0) < 1000.0 * (rows < 100 ? 0.12 : 0.03), "peak tracks the tone");
    }
}

} // namespace

int main() {
    testAxisMapping();
    testWindowLength();
    testCalibration();
    testLevelMapping();
    testSlope();
    testNyquist();
    testBassResolution();
    testRows();
    TEST_MAIN_END();
}
