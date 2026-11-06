#pragma once

//
// Theme colours stored as 0xAARRGGBB, read in the Display P3 colour space.
//
// On a wide-gamut screen P3 values look more saturated than the same
// numbers read as sRGB; on an sRGB screen the system maps them back, so
// nothing is lost there. Use these helpers for every stored colour (drawing,
// colour wells, gradients) so what is picked is what is drawn.
//

#import <Cocoa/Cocoa.h>
#include <stdint.h>
#include <math.h>

static inline NSColor *JLColorFromARGB(uint32_t argb) {
    return [NSColor colorWithDisplayP3Red:((argb >> 16) & 0xFF) / 255.0
                                    green:((argb >> 8) & 0xFF) / 255.0
                                     blue:(argb & 0xFF) / 255.0
                                    alpha:((argb >> 24) & 0xFF) / 255.0];
}

static inline uint32_t JLColorChannel8(CGFloat v) {
    return (uint32_t)lround(fmin(fmax(v, 0.0), 1.0) * 255.0) & 0xFF;
}

// Opaque black when the colour cannot be expressed in Display P3.
static inline uint32_t JLARGBFromColor(NSColor *color) {
    NSColor *c = [color colorUsingColorSpace:[NSColorSpace displayP3ColorSpace]];
    if (!c) return 0xFF000000u;
    return (JLColorChannel8(c.alphaComponent) << 24) | (JLColorChannel8(c.redComponent) << 16) |
           (JLColorChannel8(c.greenComponent) << 8) | JLColorChannel8(c.blueComponent);
}

// Colour space for gradients and bitmaps built from theme colours, so they
// keep the P3 saturation instead of being clipped to sRGB. Caller releases.
static inline CGColorSpaceRef JLCreateThemeColorSpace(void) {
    return CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
}
