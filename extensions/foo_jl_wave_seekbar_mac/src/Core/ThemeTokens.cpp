//
//  ThemeTokens.cpp
//  foo_wave_seekbar_mac
//

#include "ThemeTokens.h"
#include <algorithm>
#include <cmath>

namespace theme {

namespace {
    const float kPi = 3.14159265358979323846f;

    float toLinear(float c) {
        return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f);
    }
    float toGamma(float c) {
        return c <= 0.0031308f ? c * 12.92f : 1.055f * std::pow(c, 1.0f / 2.4f) - 0.055f;
    }

    // OKLCH -> linear sRGB, unclamped
    void oklchToLinear(const Oklch& c, float out[3]) {
        const float a = c.C * std::cos(c.h * kPi / 180.0f);
        const float b = c.C * std::sin(c.h * kPi / 180.0f);
        float l = c.L + 0.3963377774f * a + 0.2158037573f * b;
        float m = c.L - 0.1055613458f * a - 0.0638541728f * b;
        float s = c.L - 0.0894841775f * a - 1.2914855480f * b;
        l = l * l * l; m = m * m * m; s = s * s * s;
        out[0] =  4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s;
        out[1] = -1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s;
        out[2] = -0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s;
    }

    bool inGamut(const float lin[3]) {
        const float e = 1e-4f;
        return lin[0] >= -e && lin[0] <= 1 + e && lin[1] >= -e && lin[1] <= 1 + e && lin[2] >= -e && lin[2] <= 1 + e;
    }

    RGB fromLinear(const float lin[3]) {
        RGB out;
        out.r = toGamma(std::clamp(lin[0], 0.0f, 1.0f));
        out.g = toGamma(std::clamp(lin[1], 0.0f, 1.0f));
        out.b = toGamma(std::clamp(lin[2], 0.0f, 1.0f));
        return out;
    }
}

RGB RGB::fromARGB(uint32_t argb) {
    RGB c;
    c.r = ((argb >> 16) & 0xFF) / 255.0f;
    c.g = ((argb >> 8) & 0xFF) / 255.0f;
    c.b = (argb & 0xFF) / 255.0f;
    return c;
}

Oklch toOklch(const RGB& c) {
    const float r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b);
    const float l = std::cbrt(0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * b);
    const float m = std::cbrt(0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * b);
    const float s = std::cbrt(0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * b);
    const float L = 0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s;
    const float A = 1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s;
    const float B = 0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s;
    Oklch out;
    out.L = L;
    out.C = std::sqrt(A * A + B * B);
    out.h = std::atan2(B, A) * 180.0f / kPi;
    if (out.h < 0) out.h += 360.0f;
    return out;
}

RGB fromOklch(const Oklch& c) {
    Oklch t = c;
    t.L = std::clamp(t.L, 0.0f, 1.0f);
    float lin[3];
    oklchToLinear(t, lin);
    if (inGamut(lin)) return fromLinear(lin);

    // Bisect the chroma down to the gamut edge
    float lo = 0.0f, hi = t.C;
    for (int i = 0; i < 24; ++i) {
        t.C = (lo + hi) * 0.5f;
        oklchToLinear(t, lin);
        if (inGamut(lin)) lo = t.C; else hi = t.C;
    }
    t.C = lo;
    oklchToLinear(t, lin);
    return fromLinear(lin);
}

RGB mix(const RGB& a, const RGB& b, float t) {
    return { a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t };
}

float luminance(const RGB& c) {
    return 0.2126f * toLinear(c.r) + 0.7152f * toLinear(c.g) + 0.0722f * toLinear(c.b);
}

bool isDark(const RGB& background) {
    return luminance(background) < 0.18f;
}

Tokens deriveTokens(const RGB& accent, const RGB& background) {
    const Oklch a = toOklch(accent);
    const Oklch bg = toOklch(background);
    const bool dark = isDark(background);
    const float dir = dark ? 1.0f : -1.0f;

    Tokens t;
    t.accent = accent;
    t.background = background;
    t.deep = fromOklch({ a.L * 0.55f, a.C * 0.85f, a.h });
    t.hot = fromOklch({ 0.96f, std::min(0.05f, a.C * 0.35f), a.h });
    // Guides take the accent's hue only when it has one
    const float hue = a.C > 0.02f ? a.h : bg.h;
    t.grid = fromOklch({ bg.L + dir * 0.055f, std::min(0.016f, a.C), hue });
    t.centre = fromOklch({ bg.L + dir * 0.146f, std::min(0.024f, a.C), hue });
    t.cursor = dark ? fromOklch({ 0.953f, std::min(0.018f, a.C), hue })
                    : fromOklch({ 0.22f, std::min(0.018f, a.C), hue });
    t.cursorText = dark ? fromOklch({ 0.18f, std::min(0.01f, a.C), hue })
                        : fromOklch({ 0.97f, std::min(0.01f, a.C), hue });
    return t;
}

RGB tintColor(const RGB& accent, float position, float strength) {
    const float u = (std::clamp(position, 0.0f, 1.0f) - 0.5f) * 2.0f * std::clamp(strength, 0.0f, 1.0f);
    if (u == 0.0f) return accent;
    const Oklch a = toOklch(accent);
    Oklch c = a;
    c.L = a.L + u * (u < 0.0f ? 0.10f : 0.07f);
    c.C = a.C * (1.0f + 0.1f * std::fabs(u));
    c.h = a.h + 14.0f * u;
    if (c.h < 0.0f) c.h += 360.0f;
    if (c.h >= 360.0f) c.h -= 360.0f;
    return fromOklch(c);
}

} // namespace theme
