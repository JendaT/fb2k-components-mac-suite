//
//  ThemeTokensTests.cpp
//  foo_jl_wave_seekbar_mac
//
//  Unit tests for OKLCH conversion and the derived colour tokens.
//  Standalone: no SDK, no Xcode.
//

#include "TestHarness.h"
#include "../src/Core/ThemeTokens.h"

#include <cmath>

using namespace waveseek::theme;

namespace {

#define CHECK_NEAR(actual, expected, tol, what)                                  \
    do {                                                                         \
        g_checks++;                                                             \
        double chk_a = (actual), chk_e = (expected);                            \
        if (!(std::fabs(chk_a - chk_e) <= (tol))) {                             \
            g_failures++;                                                       \
            printf("FAIL %s:%d [%s] %s: got %f, expected %f +- %f\n",           \
                   __FILE__, __LINE__, g_context.c_str(), what, chk_a, chk_e,   \
                   (double)(tol));                                              \
        }                                                                       \
    } while (0)

RGB hex(uint32_t rgb) { return RGB::fromARGB(0xFF000000u | rgb); }

float hueDistance(float a, float b) {
    float d = std::fabs(a - b);
    return d > 180.0f ? 360.0f - d : d;
}

void testConversion() {
    g_context = "oklch";
    // Reference values (Björn Ottosson's OKLab)
    const Oklch white = toOklch(hex(0xFFFFFF));
    CHECK_NEAR(white.L, 1.0, 0.001, "white L");
    CHECK_NEAR(white.C, 0.0, 0.001, "white C");
    const Oklch amber = toOklch(hex(0xE8B547));
    CHECK_NEAR(amber.L, 0.800, 0.002, "amber L");
    CHECK_NEAR(amber.C, 0.137, 0.002, "amber C");
    CHECK_NEAR(amber.h, 83.35, 0.5, "amber h");

    for (uint32_t c : { 0xE8B547u, 0x8C9EEBu, 0x13110Cu, 0x6FB7FFu, 0x000000u }) {
        const RGB in = hex(c), out = fromOklch(toOklch(in));
        CHECK_NEAR(out.r, in.r, 0.002, "round trip r");
        CHECK_NEAR(out.g, in.g, 0.002, "round trip g");
        CHECK_NEAR(out.b, in.b, 0.002, "round trip b");
    }

    g_context = "gamut";
    const RGB clipped = fromOklch({ 0.9f, 0.4f, 30.0f });   // far outside sRGB
    CHECK(clipped.r >= 0 && clipped.r <= 1 && clipped.g >= 0 && clipped.g <= 1 && clipped.b >= 0 && clipped.b <= 1,
          "in range");
    CHECK_NEAR(toOklch(clipped).L, 0.9, 0.01, "lightness kept");
    CHECK(hueDistance(toOklch(clipped).h, 30.0f) < 3.0f, "hue kept");
}

void testTokens() {
    // The handoff's amber and blue themes, derived from their accents alone
    struct Case { uint32_t accent, deep, hot; };
    for (Case cs : { Case{ 0xE8B547, 0x7A4A12, 0xFFF2C8 }, Case{ 0x8C9EEB, 0x2E3A8C, 0xEEF1FF } }) {
        g_context = "tokens " + std::to_string(cs.accent);
        const Tokens t = deriveTokens(hex(cs.accent), hex(0x13110C));
        const Oklch a = toOklch(hex(cs.accent)), deep = toOklch(t.deep), hot = toOklch(t.hot);
        CHECK_NEAR(deep.L, toOklch(hex(cs.deep)).L, 0.03, "deep lightness close to the spec");
        CHECK(hueDistance(deep.h, a.h) < 2.0f, "deep keeps the hue");
        CHECK(deep.C < a.C, "deep has less chroma");
        CHECK_NEAR(hot.L, 0.96, 0.01, "hot lightness");
        CHECK(hot.C <= 0.051f, "hot chroma is low");
        CHECK(hueDistance(hot.h, a.h) < 3.0f, "hot keeps the hue");
    }

    g_context = "guides";
    const Tokens dark = deriveTokens(hex(0xE8B547), hex(0x13110C));
    CHECK_NEAR(toOklch(dark.grid).L, toOklch(hex(0x211D15)).L, 0.01, "grid as in the spec");
    CHECK_NEAR(toOklch(dark.centre).L, toOklch(hex(0x3A3326)).L, 0.01, "centre as in the spec");
    CHECK(toOklch(dark.cursor).L > 0.9f, "light cursor on dark");

    const Tokens light = deriveTokens(hex(0x2D6CC0), hex(0xF0F4F9));
    CHECK(toOklch(light.grid).L < toOklch(hex(0xF0F4F9)).L, "grid darker than a light background");
    CHECK(toOklch(light.cursor).L < 0.3f, "dark cursor on light");
    CHECK(isDark(hex(0x0A0E15)) && !isDark(hex(0xF0F4F9)), "isDark");
}

void testTint() {
    g_context = "tint";
    for (uint32_t c : { 0xFFB000u, 0x6FB7FFu, 0x4CFF7Cu }) {
        const RGB accent = hex(c);
        const Oklch a = toOklch(accent), mid = toOklch(tintColor(accent, 0.5f));
        const Oklch bass = toOklch(tintColor(accent, 0.0f)), bright = toOklch(tintColor(accent, 1.0f));
        CHECK_NEAR(mid.L, a.L, 0.003, "the middle is the accent");
        CHECK(bass.L < a.L - 0.08f, "bass-heavy is darker");
        CHECK(bright.L > a.L + 0.03f, "bright is lighter");
        CHECK(bass.C > a.C * 0.95f, "bass-heavy keeps its saturation");
        CHECK(hueDistance(bass.h, a.h) > 8.0f && hueDistance(bass.h, a.h) < 20.0f, "hue turns one way");
        CHECK(toOklch(tintColor(accent, 0.25f)).L < a.L && toOklch(tintColor(accent, 0.75f)).L > a.L, "monotonic");
        CHECK(toOklch(tintColor(accent, -1.0f)).L == bass.L, "clamped");
        const Oklch half = toOklch(tintColor(accent, 0.0f, 0.5f));
        CHECK(half.L < a.L && half.L > bass.L, "half strength sits between");
        CHECK(tintColor(accent, 0.0f, 0.0f) == accent, "no strength gives the accent");
    }
}

} // namespace

int main() {
    testConversion();
    testTokens();
    testTint();
    TEST_MAIN_END();
}
