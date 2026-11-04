//
//  CursorFxTests.cpp
//  foo_wave_seekbar_mac
//

#include "TestSupport.h"
#include "../src/Core/CursorFx.h"

#include <limits>
#include <vector>

using namespace waveseek::fx;

namespace {

void testHashAndNoise() {
    TEST_CASE("hash and noise");

    CHECK(hash(12345u) == hash(12345u), "a hash is a function of its input");
    CHECK(hash(1u, 2u) != hash(2u, 1u), "argument order matters");
    double sum = 0.0;
    bool inRange = true;
    for (uint32_t i = 0; i < 10000; ++i) {
        const float u = unit(hash(i, 7u));
        inRange = inRange && u >= 0.0f && u < 1.0f;
        sum += u;
    }
    CHECK(inRange, "unit() stays in [0, 1)");
    CHECK_NEAR(sum / 10000.0, 0.5, 0.02, "unit() averages a half");

    bool bounded = true, smooth = true;
    for (int i = 0; i < 2000; ++i) {
        const float x = -50.0f + i * 0.05f;
        const float n = noise1(x, 3u);
        bounded = bounded && n >= -1.0f && n <= 1.0f;
        smooth = smooth && std::fabs(noise1(x + 0.001f, 3u) - n) < 0.01f;
    }
    CHECK(bounded, "noise1 stays in -1..1");
    CHECK(smooth, "noise1 has no jumps");
    CHECK_NEAR(noise1(4.0f - 1e-4f, 9u), noise1(4.0f, 9u), 1e-3, "continuous across a lattice point");

    bool periodic = true;
    for (int i = 0; i < 200; ++i) {
        const float x = i * 0.37f, y = i * 0.53f;
        const float n = noise2(x, y, 6, 5u);
        periodic = periodic && std::fabs(noise2(x + 6.0f, y, 6, 5u) - n) < 1e-4f &&
                   std::fabs(noise2(x, y + 6.0f, 6, 5u) - n) < 1e-4f && n >= -1.0f && n <= 1.0f;
    }
    CHECK(periodic, "noise2 repeats every period in x and y, within -1..1");
}

void testGlow() {
    TEST_CASE("glow falloff");

    CHECK_NEAR(glowFalloff(0.0f, 5.0f, 25.0f), 1.0, 1e-6, "full at the line");
    CHECK_NEAR(glowFalloff(25.0f, 5.0f, 25.0f), 0.0, 1e-6, "nothing at the reach: no edge");
    CHECK_NEAR(glowFalloff(40.0f, 5.0f, 25.0f), 0.0, 1e-6, "nothing beyond it");
    CHECK_NEAR(glowFalloff(-7.0f, 5.0f, 25.0f), glowFalloff(7.0f, 5.0f, 25.0f), 1e-6, "the same both sides");
    CHECK(glowFalloff(5.0f, 5.0f, 25.0f) < 0.55f && glowFalloff(5.0f, 5.0f, 25.0f) > 0.4f,
          "about half at one radius, as light from a line");
    CHECK_NEAR(glowFalloff(1.0f, 0.0f, 25.0f), 0.0, 1e-6, "no radius, no light");

    bool falls = true;
    for (int i = 1; i <= 100; ++i) {
        falls = falls && glowFalloff(i * 0.25f, 5.0f, 25.0f) <= glowFalloff((i - 1) * 0.25f, 5.0f, 25.0f);
    }
    CHECK(falls, "falls off with distance");

    const auto stops = glowStops(5.0f);
    CHECK_NEAR(stops.front().location, 0.0, 1e-6, "first stop at the line");
    CHECK_NEAR(stops.front().alpha, 1.0, 1e-6, "and full");
    CHECK_NEAR(stops.back().location, 1.0, 1e-6, "last stop at the reach");
    CHECK_NEAR(stops.back().alpha, 0.0, 1e-6, "and clear");
    bool ordered = true;
    for (size_t i = 1; i < stops.size(); ++i) {
        ordered = ordered && stops[i].location > stops[i - 1].location && stops[i].alpha <= stops[i - 1].alpha;
    }
    CHECK(ordered, "stops move out and dim");
    CHECK(stops[1].location < 1.0f / (kGlowStops - 1), "closer together near the line");
}

// RMS blocks: `quiet` everywhere with `loud` from block `from` on
std::vector<float> stepBlocks(size_t count, size_t from, float quiet, float loud) {
    std::vector<float> v(count, quiet);
    for (size_t i = from; i < count; ++i) v[i] = loud;
    return v;
}

void testLevelEnvelope() {
    TEST_CASE("level envelope");
    const double block = 0.01;

    LevelEnvelope empty;
    CHECK(empty.empty(), "starts empty");
    CHECK_NEAR(empty.level(1.0), 0.0, 1e-9, "no level without data");
    empty.build(nullptr, nullptr, 10, block);
    CHECK(empty.empty(), "no data, nothing built");
    const std::vector<float> silence(100, 0.0f);
    empty.build(silence.data(), nullptr, silence.size(), block);
    CHECK(empty.empty(), "silence builds nothing: no bursts");
    CHECK_NEAR(empty.burst(0.5), 0.0, 1e-9, "silence never bursts");

    const std::vector<float> steady(200, 0.3f);
    LevelEnvelope e;
    e.build(steady.data(), nullptr, steady.size(), block);
    CHECK(!e.empty(), "built");
    CHECK_NEAR(e.level(1.0), 1.0, 1e-5, "a steady track sits at its own reference");
    CHECK_NEAR(e.onset(1.0), 0.0, 1e-5, "no onsets once it is going");
    CHECK_NEAR(e.burst(1.0), 0.5, 1e-4, "loudness alone bursts a little");
    CHECK_NEAR(e.smooth(1.0), 1.0, 1e-5, "the average of a steady level is the level");
    CHECK_NEAR(e.level(-1.0), 0.0, 1e-9, "nothing before the track");
    CHECK_NEAR(e.level(2.5), 0.0, 1e-9, "nothing after it");
    CHECK_NEAR(e.level(std::numeric_limits<double>::quiet_NaN()), 0.0, 1e-9, "nothing at NaN");

    // A quiet recording of the same shape gives the same levels
    std::vector<float> quiet(steady);
    for (float& v : quiet) v *= 0.05f;
    LevelEnvelope q;
    q.build(quiet.data(), nullptr, quiet.size(), block);
    CHECK_NEAR(q.level(1.0), e.level(1.0), 1e-5, "levels are relative to the track");

    // Mono is the same as two identical channels
    LevelEnvelope stereo;
    stereo.build(steady.data(), steady.data(), steady.size(), block);
    CHECK_NEAR(stereo.level(0.7), e.level(0.7), 1e-6, "mono and dual mono agree");

    // A step up: an onset at the step that dies away within the window
    const std::vector<float> step = stepBlocks(400, 200, 0.1f, 0.4f);
    LevelEnvelope s;
    s.build(step.data(), nullptr, step.size(), block);
    const double at = 200 * block + block / 2;      // centre of the first loud block
    CHECK(s.onset(at) > 0.5f, "the step is an onset");
    CHECK(s.burst(at) > 1.0f, "and bursts");
    CHECK_NEAR(s.onset(at + 0.3), 0.0, 1e-5, "the onset is gone once the window has passed");
    CHECK(s.burst(at - 0.5) < 0.05f, "the quiet part barely bursts");
    CHECK(s.burst(at) <= LevelEnvelope::kMaxBurst, "bursts are capped");
    CHECK(s.smooth(at) < s.level(at), "the trailing average lags the step");
    CHECK_NEAR(s.level(at - block / 2), (s.level(at - block) + s.level(at)) / 2.0, 1e-5,
               "linear between block centres");
}

void testSparks() {
    TEST_CASE("sparks");
    const SparkParams p = particleSparks();
    std::vector<Spark> out;

    sparksAt(5.0, p, [](double) { return 0.0f; }, out);
    CHECK(out.empty(), "no strength, no sparks");
    sparksAt(-1.0, p, [](double) { return 1.0f; }, out);
    CHECK(out.empty(), "none before the track");
    sparksAt(std::numeric_limits<double>::quiet_NaN(), p, [](double) { return 1.0f; }, out);
    CHECK(out.empty(), "none at NaN");

    auto strong = [](double) { return 10.0f; };     // beyond kMaxBurst: clamped
    sparksAt(30.0, p, strong, out);
    CHECK(!out.empty(), "a burst throws sparks");
    CHECK(out.size() <= maxSparks(p), "never more than maxSparks");
    std::vector<Spark> again;
    sparksAt(30.0, p, strong, again);
    bool same = again.size() == out.size();
    for (size_t i = 0; same && i < out.size(); ++i) {
        same = again[i].born == out[i].born && again[i].dx == out[i].dx && again[i].rise == out[i].rise;
    }
    CHECK(same, "the same time gives the same sparks");

    bool sane = true;
    for (const Spark& s : out) {
        sane = sane && s.age >= 0.0f && s.age < 1.0f && s.alpha > 0.0f && s.alpha <= 1.0f && s.rise >= 0.0f &&
               s.pick >= 0.0f && s.pick < 1.0f && s.edge >= 0.6f && s.edge <= 1.0f && s.size > 0.0f &&
               s.size <= p.maxSize && s.born <= 30.0 && s.born > 30.0 - p.lifetime - p.slotSeconds &&
               s.heat >= 0.0f && s.heat <= 1.0f;
    }
    CHECK(sane, "every spark is alive, outside the wave, within its bounds");

    // Louder throws more, on average over many frames
    size_t loud = 0, soft = 0;
    for (int f = 0; f < 120; ++f) {
        const double t = 10.0 + f / 60.0;
        sparksAt(t, p, [](double) { return 1.0f; }, out);
        loud += out.size();
        sparksAt(t, p, [](double) { return 0.2f; }, out);
        soft += out.size();
    }
    CHECK(loud > 3 * soft, "louder means more sparks");
    CHECK(soft > 0, "a weak burst still shows now and then");

    // A spark seen in one frame is the same spark a frame later, further on
    sparksAt(20.0, p, strong, out);
    sparksAt(20.0 + 1.0 / 60.0, p, strong, again);
    size_t matched = 0, young = 0;
    for (const Spark& s : out) {
        if (s.age > 0.5f) continue;
        ++young;
        for (const Spark& n : again) {
            if (n.born == s.born && n.pick == s.pick) {
                matched += n.age > s.age ? 1 : 0;
                break;
            }
        }
    }
    CHECK(young > 0 && matched * 10 >= young * 9, "sparks carry on from frame to frame, older");

    // Embers rise: negative gravity never brings them back
    sparksAt(15.0, emberSparks(), [](double) { return 1.0f; }, out);
    bool rising = !out.empty();
    for (const Spark& s : out) rising = rising && s.rise >= 0.0f;
    CHECK(rising, "embers keep rising");
    CHECK(maxSparks(debrisSparks()) > 0 && maxSparks(emberSparks()) > 0, "every preset has room");
    SparkParams broken = p;
    broken.slotSeconds = 0.0;
    CHECK(maxSparks(broken) == 0, "a bad slot length allows none");
    sparksAt(5.0, broken, strong, out);
    CHECK(out.empty(), "and makes none");
}

// Height below which `share` of the field's heat lies, in rows
double heatHeight(const FireField& f, double share) {
    std::vector<double> rows((size_t)f.height(), 0.0);
    double total = 0.0;
    for (int y = 0; y < f.height(); ++y) {
        for (int x = 0; x < f.width(); ++x) rows[(size_t)y] += f.at(x, y);
        total += rows[(size_t)y];
    }
    double sum = 0.0;
    for (int y = 0; y < f.height(); ++y) {
        sum += rows[(size_t)y];
        if (sum >= share * total) return y;
    }
    return f.height();
}

void testFireField() {
    TEST_CASE("fire field");

    FireField f;
    f.resize(40, 100, 24);
    CHECK(f.width() == 40 && f.height() == 100 && f.source() == 24, "sized as asked");
    bool cold = true;
    for (int y = 0; y < 100; ++y) for (int x = 0; x < 40; ++x) cold = cold && f.at(x, y) == 0;
    CHECK(cold, "starts cold");

    for (int i = 0; i < 200; ++i) f.step(1.0f);
    CHECK(f.at(24, 0) > 200, "the bed burns hot at the source");
    CHECK(f.at(0, 0) < 40 && f.at(39, 0) < 40, "and dies out before the sides");
    CHECK(heatHeight(f, 0.9) > 30.0, "flames climb well up the field");

    FireField low, high;
    low.resize(40, 100, 24, 99u);
    high.resize(40, 100, 24, 99u);
    double lowH = 0.0, highH = 0.0;
    for (int i = 0; i < 400; ++i) {
        low.step(0.2f);
        high.step(1.3f);
        if (i >= 200) {
            lowH += heatHeight(low, 0.9);
            highH += heatHeight(high, 0.9);
        }
    }
    CHECK(highH > lowH * 1.15, "more fuel, taller flames");

    FireField a, b;
    a.resize(30, 60, 18, 7u);
    b.resize(30, 60, 18, 7u);
    for (int i = 0; i < 50; ++i) {
        a.step(0.9f);
        b.step(0.9f);
    }
    bool same = true;
    for (int y = 0; y < 60; ++y) for (int x = 0; x < 30; ++x) same = same && a.at(x, y) == b.at(x, y);
    CHECK(same, "the same seed and fuel give the same fire");

    // Degenerate sizes and fuel don't break it
    FireField tiny;
    tiny.resize(0, 0, 5);
    for (int i = 0; i < 10; ++i) tiny.step(std::numeric_limits<float>::quiet_NaN());
    CHECK(tiny.width() == 1 && tiny.height() == 1 && tiny.source() == 0, "clamped to one cell");

    // Palette: premultiplied, clear when cold, opaque and pale when hottest
    const auto& c0 = FireField::colour(0);
    const auto& c255 = FireField::colour(255);
    CHECK(c0[3] == 0 && c0[0] == 0, "cold is clear");
    CHECK(c255[3] == 255 && c255[0] > 240 && c255[1] > 230 && c255[2] > 150, "the hottest is nearly white");
    bool premultiplied = true;
    for (int h = 0; h < 256; ++h) {
        const auto& c = FireField::colour((uint8_t)h);
        premultiplied = premultiplied && c[0] <= c[3] && c[1] <= c[3] && c[2] <= c[3];
    }
    CHECK(premultiplied, "colour never exceeds alpha");

    std::vector<uint8_t> rgba((size_t)f.width() * f.height() * 4, 0);
    f.paint(rgba.data(), (size_t)f.width() * 4);
    const size_t lastRow = (size_t)(f.height() - 1) * f.width() * 4;
    CHECK(rgba[lastRow + 24 * 4 + 3] > 200, "the bed is the image's bottom row");
    CHECK(rgba[3] < 40, "the far top corner is clear");
}

void testCracks() {
    TEST_CASE("crack tile");

    const CrackTile t = makeCrackTile(64, 4, 11u);
    CHECK(t.size == 64 && t.crack.size() == 64 * 64 && t.glow.size() == 64 * 64 && t.plate.size() == 64 * 64,
          "sized as asked");
    size_t cracked = 0;
    uint8_t lo = 255, hi = 0;
    bool mainCracksGlow = true;
    for (size_t i = 0; i < t.crack.size(); ++i) {
        cracked += t.crack[i] > 128 ? 1 : 0;
        lo = std::min(lo, t.plate[i]);
        hi = std::max(hi, t.plate[i]);
        // A crack this dark is a main one (fine ones peak at 55 %): it glows
        if (t.crack[i] > 200) mainCracksGlow = mainCracksGlow && t.glow[i] > 128;
    }
    CHECK(cracked > t.crack.size() / 20 && cracked < t.crack.size() / 2, "cracks, but mostly pieces");
    CHECK(mainCracksGlow, "the embers cover the main cracks");
    CHECK(hi - lo > 80, "the pieces differ in shade");

    // The cells repeat with the tile, so the tile repeats without a seam
    bool repeats = true;
    for (int i = 0; i < 100; ++i) {
        const float x = i * 0.137f, y = i * 0.291f;
        const detail::CellHit a = detail::voronoi(x, y, 4, 11u);
        const detail::CellHit b = detail::voronoi(x + 4.0f, y, 4, 11u);
        const detail::CellHit c = detail::voronoi(x, y - 4.0f, 4, 11u);
        repeats = repeats && std::fabs(a.edge - b.edge) < 1e-4f && std::fabs(a.edge - c.edge) < 1e-4f &&
                  a.cell == b.cell && a.cell == c.cell;
    }
    CHECK(repeats, "the cells repeat every tile");
    const CrackTile u = makeCrackTile(64, 4, 11u);
    CHECK(u.crack == t.crack && u.plate == t.plate, "the same seed gives the same tile");
    CHECK(makeCrackTile(0, 4, 1u).size == 0 && makeCrackTile(16, 0, 1u).crack.empty(), "nothing for no size");

    CHECK_NEAR(scorchFade(0.0f), 1.0, 1e-6, "scorch full at the cursor");
    CHECK_NEAR(scorchFade(1.0f), 0.0, 1e-6, "gone at the end of the zone");
    CHECK_NEAR(emberFade(0.0f), 1.0, 1e-6, "embers full at the cursor");
    CHECK(emberFade(0.5f) < scorchFade(0.5f), "embers die sooner than the scorch");
    bool falls = true;
    for (int i = 1; i <= 20; ++i) {
        falls = falls && scorchFade(i / 20.0f) <= scorchFade((i - 1) / 20.0f) &&
                emberFade(i / 20.0f) <= emberFade((i - 1) / 20.0f);
    }
    CHECK(falls, "both fade with distance");
}

void testJaggedLine() {
    TEST_CASE("jagged line");

    std::vector<std::array<float, 2>> pts;
    jaggedLine(103.0f, 5.0f, 4.0f, 12.5, 1u, pts);
    CHECK(pts.size() == 22, "a vertex every step, both ends included");
    CHECK_NEAR(pts.front()[1], 0.0, 1e-6, "starts at the bottom");
    CHECK_NEAR(pts.back()[1], 103.0, 1e-6, "ends at the top");
    bool within = true, rising = true;
    float spread = 0.0f;
    for (size_t i = 0; i < pts.size(); ++i) {
        within = within && std::fabs(pts[i][0]) <= 4.0f + 1e-6f && pts[i][1] >= 0.0f && pts[i][1] <= 103.0f;
        if (i > 0) rising = rising && pts[i][1] >= pts[i - 1][1];
        spread = std::max(spread, std::fabs(pts[i][0]));
    }
    CHECK(within, "within the amplitude and the height");
    CHECK(rising, "climbs without folding back");
    CHECK(spread > 1.0f, "actually jagged");

    std::vector<std::array<float, 2>> same, later;
    jaggedLine(103.0f, 5.0f, 4.0f, 12.5, 1u, same);
    jaggedLine(103.0f, 5.0f, 4.0f, 13.0, 1u, later);
    CHECK(same == pts, "the same time gives the same line");
    bool moved = false;
    for (size_t i = 0; i < pts.size(); ++i) moved = moved || later[i][0] != pts[i][0];
    CHECK(moved, "it morphs over time");

    jaggedLine(50.0f, 5.0f, 0.0f, 3.0, 1u, pts);
    bool straight = true;
    for (const auto& p : pts) straight = straight && p[0] == 0.0f;
    CHECK(straight, "no amplitude, a straight line");
    jaggedLine(0.0f, 5.0f, 4.0f, 3.0, 1u, pts);
    CHECK(pts.empty(), "no height, no line");
    jaggedLine(50.0f, 5.0f, 4.0f, std::numeric_limits<double>::infinity(), 1u, pts);
    CHECK(pts.empty(), "no line at an infinite time");
    jaggedLine(50.0f, 5.0f, 4.0f, 8.0e8, 1u, pts);
    bool finite = !pts.empty();
    for (const auto& p : pts) finite = finite && std::isfinite(p[0]);
    CHECK(finite, "wall-clock times stay finite");
}

} // namespace

int main() {
    testHashAndNoise();
    testGlow();
    testLevelEnvelope();
    testSparks();
    testFireField();
    testCracks();
    testJaggedLine();
    return testsupport::summarize("CursorFxTests");
}
