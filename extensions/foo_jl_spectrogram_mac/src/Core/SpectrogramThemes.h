//
//  SpectrogramThemes.h
//  foo_jl_spectrogram_mac
//
//  Applying a colormap preset to the stored colors: the custom ramp's four
//  color wells start from the preset, and a theme ramp also brings its
//  Spectrum Analyzer panel colors.
//

#pragma once

#include "SpectrogramConfig.h"
#include "SpectrogramColormaps.h"
#include <CoreGraphics/CoreGraphics.h>
#include <cmath>

namespace spectrogram_config {

// The same color in Display P3 numbers. Stored colors are P3; a general-purpose
// map seeding them is sRGB, so it is converted to keep its look.
inline uint32_t srgbToDisplayP3(uint32_t argb) {
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorSpaceRef p3 = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    const CGFloat in[4] = {((argb >> 16) & 0xFF) / 255.0, ((argb >> 8) & 0xFF) / 255.0,
                           (argb & 0xFF) / 255.0, ((argb >> 24) & 0xFF) / 255.0};
    CGColorRef from = CGColorCreate(srgb, in);
    CGColorRef to = from ? CGColorCreateCopyByMatchingToColorSpace(p3, kCGRenderingIntentDefault, from, NULL) : NULL;
    uint32_t out = argb;
    if (to && CGColorGetNumberOfComponents(to) == 4) {
        const CGFloat* c = CGColorGetComponents(to);
        auto channel = [](CGFloat v) { return (uint32_t)std::lround(std::fmin(std::fmax(v, 0.0), 1.0) * 255.0) & 0xFF; };
        out = (channel(c[3]) << 24) | (channel(c[0]) << 16) | (channel(c[1]) << 8) | channel(c[2]);
    }
    if (to) CGColorRelease(to);
    if (from) CGColorRelease(from);
    CGColorSpaceRelease(p3);
    CGColorSpaceRelease(srgb);
    return out;
}

// Map `index`'s color at custom stop `i`, as the Display P3 the custom ramp
// is stored in.
inline uint32_t customColorSeed(int index, int i) {
    const uint32_t c = 0xFF000000u | spectrogram_colormap::customColorFromMap(index, i);
    return spectrogram_colormap::isDisplayP3Map(index) ? c : srgbToDisplayP3(c);
}

// Custom ramp color `i` (0..kCustomColorCount-1) as stored, seeded from the
// default colormap until the user edits it.
inline uint32_t customColor(int i) {
    return (uint32_t)getConfigInt(kKeyCustomColors[i], customColorSeed(kDefaultColormap, i));
}

// Write a preset's colors into config. No-op for the custom map. Theme ramp
// and panel numbers are already Display P3, like the Spectrum Analyzer's.
inline void applyColormapToConfig(int index) {
    using namespace spectrogram_colormap;
    if (index < 0 || index >= kMapCount) return;
    for (int i = 0; i < kCustomColorCount; ++i) {
        setConfigInt(kKeyCustomColors[i], customColorSeed(index, i));
    }
    if (index >= kFirstThemeMap) {
        const ThemePanel& t = kThemePanels[index - kFirstThemeMap];
        setConfigInt(kKeyBgColorLight, t.bgLight);
        setConfigInt(kKeyGridColorLight, t.gridLight);
        setConfigInt(kKeyBgColorDark, t.bgDark);
        setConfigInt(kKeyGridColorDark, t.gridDark);
    }
}

} // namespace spectrogram_config
