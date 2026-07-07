//
//  ScrobbleColorUtils.h
//  foo_jl_scrobble_mac
//
//  Single definition of the ARGB <-> NSColor conversions previously
//  duplicated across the widget and preferences controllers. The
//  bit-packing is pure; NSColor construction is the only AppKit touch.
//

#pragma once

#import <AppKit/AppKit.h>

/// 0xAARRGGBB -> NSColor (calibrated RGB, matching the original call sites)
static inline NSColor *ScrobbleColorFromARGB(uint32_t argb) {
    return [NSColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                           green:((argb >> 8) & 0xFF) / 255.0
                            blue:(argb & 0xFF) / 255.0
                           alpha:((argb >> 24) & 0xFF) / 255.0];
}

/// Preferences variant: alpha 0 means "unset", falls back to the system
/// window background
static inline NSColor *ScrobbleColorFromARGBOrWindowBackground(uint32_t argb) {
    if ((argb >> 24) == 0) {
        return [NSColor windowBackgroundColor];
    }
    return ScrobbleColorFromARGB(argb);
}

/// NSColor -> 0xAARRGGBB via sRGB (opaque black when conversion fails)
static inline uint32_t ScrobbleARGBFromColor(NSColor *color) {
    NSColor *rgbColor = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (!rgbColor) return 0xFF000000;

    uint32_t a = (uint32_t)(rgbColor.alphaComponent * 255) & 0xFF;
    uint32_t r = (uint32_t)(rgbColor.redComponent * 255) & 0xFF;
    uint32_t g = (uint32_t)(rgbColor.greenComponent * 255) & 0xFF;
    uint32_t b = (uint32_t)(rgbColor.blueComponent * 255) & 0xFF;

    return (a << 24) | (r << 16) | (g << 8) | b;
}
