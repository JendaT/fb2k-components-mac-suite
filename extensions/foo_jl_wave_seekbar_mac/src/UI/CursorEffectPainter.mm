//
//  CursorEffectPainter.mm
//  foo_wave_seekbar_mac
//

#include "CursorEffectPainter.h"
#include <algorithm>
#include <cmath>

namespace waveseek::fx {

namespace {

constexpr double kFireStepsPerSecond = 120.0;   // a row a step: flames rise ~100 pt/s
constexpr int kFireMaxStepsPerFrame = 6;        // after a stall the fire catches up only this much
constexpr int kTilePixels = 128;            // the crack tile, drawn kTilePoints a side
constexpr CGFloat kTilePoints = 64.0;
constexpr int kTileCells = 5;
constexpr size_t kRampPixels = 64;
constexpr int kAlphaSteps = 6;              // sparks are filled in this many batches by alpha
constexpr int kGradientSteps = 8;

// Fire and scorched earth keep their own colours in every theme
const Colour kCharMid = { 0.42, 0.29, 0.17 };
const Colour kCharDark = { 0.045, 0.03, 0.02 };
const Colour kEmberRed = { 1.0, 0.30, 0.04 };
const Colour kEmberYellow = { 1.0, 0.84, 0.42 };

Colour mix(Colour a, Colour b, CGFloat t) {
    return { a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t };
}

void fill(CGContextRef ctx, CGColorSpaceRef space, Colour c, CGFloat alpha) {
    const CGFloat comps[4] = { c.r, c.g, c.b, alpha };
    CGContextSetFillColorSpace(ctx, space);
    CGContextSetFillColor(ctx, comps);
}

void stroke(CGContextRef ctx, CGColorSpaceRef space, Colour c, CGFloat alpha) {
    const CGFloat comps[4] = { c.r, c.g, c.b, alpha };
    CGContextSetStrokeColorSpace(ctx, space);
    CGContextSetStrokeColor(ctx, comps);
}

// Premultiplied RGBA bytes, top row first
CGImageRef createImage(const std::vector<uint8_t>& rgba, int width, int height, CGColorSpaceRef space) {
    CFDataRef data = CFDataCreate(nullptr, rgba.data(), (CFIndex)rgba.size());
    if (!data) return nullptr;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    if (!provider) return nullptr;
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)width * 4, space,
                                     (CGBitmapInfo)kCGImageAlphaPremultipliedLast, provider,
                                     nullptr, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return image;
}

// A grey ramp for CGContextClipToMask, the far end of a zone on the left
// and the cursor on the right
CGImageRef createRamp(float (*fade)(float)) {
    uint8_t bytes[kRampPixels];
    for (size_t i = 0; i < kRampPixels; ++i) {
        const float u = 1.0f - (float)i / (float)(kRampPixels - 1);
        bytes[i] = (uint8_t)std::lround(std::clamp(fade(u), 0.0f, 1.0f) * 255.0f);
    }
    CFDataRef data = CFDataCreate(nullptr, bytes, (CFIndex)kRampPixels);
    if (!data) return nullptr;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    if (!provider) return nullptr;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
    CGImageRef image = CGImageCreate(kRampPixels, 1, 8, 8, kRampPixels, gray, kCGImageAlphaNone, provider,
                                     nullptr, true, kCGRenderingIntentDefault);
    CGColorSpaceRelease(gray);
    CGDataProviderRelease(provider);
    return image;
}

} // namespace

Painter::Painter(CGColorSpaceRef space)
    : space_(space ? CGColorSpaceRetain(space) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB)),
      srgb_(CGColorSpaceCreateWithName(kCGColorSpaceSRGB)) {}

Painter::~Painter() {
    CGImageRelease(scorchTile_);
    CGImageRelease(emberTile_);
    CGImageRelease(scorchRamp_);
    CGImageRelease(emberRamp_);
    CGColorSpaceRelease(space_);
    CGColorSpaceRelease(srgb_);
}

void Painter::setFill(CGContextRef ctx, Colour c, CGFloat alpha) {
    fill(ctx, space_, c, alpha);
}

#pragma mark - Glow

void Painter::glow(CGContextRef ctx, CGRect bounds, CGFloat x, Colour halo, Colour core, float pulse,
                   float strength, bool screen, float coreShare) {
    pulse = std::clamp(pulse, 0.0f, 1.0f);
    strength = std::clamp(strength, 0.0f, 1.0f);
    if (strength <= 0.0f || bounds.size.height <= 0.0) return;

    // The halo: radius 5-9 pt, reaching five radii, both sides of the line
    const float reachRadii = 5.0f;
    const CGFloat radius = 5.0 + 4.0 * pulse;
    const CGFloat reach = radius * reachRadii;
    const CGFloat peak = (0.30 + 0.35 * pulse) * strength;
    // The core: a hot line about a point either side
    const float coreReachRadii = 4.0f;
    const CGFloat coreReach = 1.0 * coreReachRadii;
    const CGFloat corePeak = (0.45 + 0.35 * pulse) * strength * std::clamp(coreShare, 0.0f, 1.0f);

    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, CGRectMake(x - reach, bounds.origin.y, 2.0 * reach, bounds.size.height));
    // Screen lightens what is under it, the waveform too, as light would
    if (screen) CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    struct Layer { Colour colour; CGFloat peak, reach; float radii; };
    // One gradient across both sides, the stops mirrored about the line: two
    // meeting at it would paint its pixel column twice
    constexpr int kMirrored = 2 * kGlowStops - 1;
    for (const Layer& layer : { Layer{ halo, peak, reach, reachRadii }, Layer{ core, corePeak, coreReach, coreReachRadii } }) {
        if (layer.peak <= 0.0) continue;
        const auto stops = glowStops(layer.radii);
        CGFloat comps[kMirrored * 4], locations[kMirrored];
        for (int i = 0; i < kMirrored; ++i) {
            const int k = std::abs(i - (kGlowStops - 1));      // 0 at the line
            const CGFloat side = i < kGlowStops - 1 ? -1.0 : 1.0;
            comps[i * 4 + 0] = layer.colour.r;
            comps[i * 4 + 1] = layer.colour.g;
            comps[i * 4 + 2] = layer.colour.b;
            comps[i * 4 + 3] = layer.peak * stops[k].alpha;
            locations[i] = 0.5 + 0.5 * side * stops[k].location;
        }
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space_, comps, locations, kMirrored);
        if (!gradient) continue;
        CGContextDrawLinearGradient(ctx, gradient, CGPointMake(x - layer.reach, 0), CGPointMake(x + layer.reach, 0), 0);
        CGGradientRelease(gradient);
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Particles

void Painter::sparks(CGContextRef ctx, const std::vector<Spark>& list, const SparkGeometry& g, Colour hot,
                     Colour cool, bool screen) {
    if (list.empty() || !g.xAt || !g.edges || g.lanes < 1) return;
    const int lanes = std::min(2, g.lanes);
    // One path per colour and alpha step, filled once: a fill per spark
    // would cost a few hundred fills a frame
    CGMutablePathRef cores[2][kAlphaSteps] = {};
    CGMutablePathRef halos[kAlphaSteps] = {};
    for (const Spark& s : list) {
        const int slot = std::min(lanes * 2 - 1, (int)(s.pick * (float)(lanes * 2)));
        const int lane = slot / 2;
        const bool up = (slot & 1) == 0;
        const CGFloat x0 = g.xAt(s.born);
        if (!std::isfinite(x0)) continue;
        CGFloat top = 0, bottom = 0;
        g.edges(x0, lane, top, bottom);
        const CGFloat out = (up ? top : bottom) * s.edge + s.rise * g.amplitude;
        const CGFloat x = x0 + s.dx;
        const CGFloat y = g.centre[lane] + (up ? out : -out);
        const int step = std::clamp((int)(s.alpha * kAlphaSteps), 0, kAlphaSteps - 1);
        const int tone = (s.heat > 0.5f && s.age < 0.4f) ? 0 : 1;
        const CGFloat r = s.size * 0.5;
        CGMutablePathRef& core = cores[tone][step];
        if (!core) core = CGPathCreateMutable();
        CGPathAddEllipseInRect(core, nullptr, CGRectMake(x - r, y - r, 2.0 * r, 2.0 * r));
        // On a dark background the young ones get a halo, so they glow. Only
        // those: hundreds of overlapping halos cost several milliseconds.
        if (!screen || s.age >= 0.35f) continue;
        CGMutablePathRef& halo = halos[step];
        if (!halo) halo = CGPathCreateMutable();
        const CGFloat hr = r * 2.6;
        CGPathAddEllipseInRect(halo, nullptr, CGRectMake(x - hr, y - hr, 2.0 * hr, 2.0 * hr));
    }
    CGContextSaveGState(ctx);
    if (screen) CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    for (int step = 0; step < kAlphaSteps; ++step) {
        const CGFloat alpha = (step + 0.5) / kAlphaSteps;
        if (halos[step]) {
            setFill(ctx, cool, alpha * 0.14);
            CGContextAddPath(ctx, halos[step]);
            CGContextFillPath(ctx);
            CGPathRelease(halos[step]);
        }
        for (int tone = 0; tone < 2; ++tone) {
            if (!cores[tone][step]) continue;
            setFill(ctx, tone == 0 ? hot : cool, alpha);
            CGContextAddPath(ctx, cores[tone][step]);
            CGContextFillPath(ctx);
            CGPathRelease(cores[tone][step]);
        }
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Firewall

void Painter::fireWall(CGContextRef ctx, CGRect rect, CGFloat x, float fuel, double now) {
    if (rect.size.height <= 0.0 || !std::isfinite(now)) return;
    // Cells of about a point (coarser on a tall view, so the field stays a
    // few thousand cells). The field is wider than the flames, which lean
    // back: the cursor sits right of its middle.
    const CGFloat cell = std::clamp(rect.size.height / 110.0, 0.75, 2.0);
    const CGFloat wall = std::clamp(rect.size.height * 0.65, 30.0, 72.0);
    const int cols = std::max(8, (int)std::lround(wall / cell));
    const int rows = std::max(8, (int)std::ceil(rect.size.height / cell));
    const int source = (int)std::lround(cols * 0.6);
    if (fire_.width() != cols || fire_.height() != rows || fire_.source() != source) {
        fire_.resize(cols, rows, source);
        for (int i = 0; i < rows; ++i) fire_.step(fuel);   // lit, not growing from nothing
        fireClock_ = now;
    }
    // Stepped by the clock, not per frame, so extra redraws don't speed it up
    int steps = 0;
    if (fireClock_ < 0.0 || now < fireClock_ || now - fireClock_ > 0.5) {
        fireClock_ = now;
        steps = 1;
    } else {
        steps = (int)((now - fireClock_) * kFireStepsPerSecond);
        fireClock_ += steps / kFireStepsPerSecond;
    }
    for (int i = 0; i < std::min(steps, kFireMaxStepsPerFrame); ++i) fire_.step(fuel);

    fireRgba_.resize((size_t)cols * (size_t)rows * 4);
    fire_.paint(fireRgba_.data(), (size_t)cols * 4);
    CGImageRef image = createImage(fireRgba_, cols, rows, srgb_);
    if (!image) return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(x - (source + 0.5) * cell, rect.origin.y, cols * cell, rows * cell), image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
}

void Painter::embers(CGContextRef ctx, const std::vector<Spark>& list, CGRect rect,
                     const std::function<CGFloat(double)>& xAt, bool screen) {
    if (list.empty() || !xAt) return;
    CGMutablePathRef paths[2][kAlphaSteps] = {};
    for (const Spark& s : list) {
        const CGFloat x = xAt(s.born) + s.dx;
        if (!std::isfinite(x)) continue;
        // Started somewhere up the wall's lower part, climbed by `rise` heights
        const CGFloat y = rect.origin.y + rect.size.height * (0.75 * s.pick + s.rise);
        const int step = std::clamp((int)(s.alpha * kAlphaSteps), 0, kAlphaSteps - 1);
        const int tone = s.age < 0.45f ? 0 : 1;
        const CGFloat r = s.size * 0.5;
        CGMutablePathRef& path = paths[tone][step];
        if (!path) path = CGPathCreateMutable();
        CGPathAddEllipseInRect(path, nullptr, CGRectMake(x - r, y - r, 2.0 * r, 2.0 * r));
    }
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    if (screen) CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    for (int step = 0; step < kAlphaSteps; ++step) {
        for (int tone = 0; tone < 2; ++tone) {
            if (!paths[tone][step]) continue;
            fill(ctx, srgb_, tone == 0 ? kEmberYellow : kEmberRed, (step + 0.5) / kAlphaSteps);
            CGContextAddPath(ctx, paths[tone][step]);
            CGContextFillPath(ctx);
            CGPathRelease(paths[tone][step]);
        }
    }
    CGContextRestoreGState(ctx);
}

#pragma mark - Earthcrusher

bool Painter::makeTiles() {
    if (tilesTried_) return scorchTile_ && emberTile_ && scorchRamp_ && emberRamp_;
    tilesTried_ = true;
    const CrackTile tile = makeCrackTile(kTilePixels, kTileCells, 0x3C6EF372u);
    const size_t n = (size_t)kTilePixels * kTilePixels;
    std::vector<uint8_t> scorch(n * 4), ember(n * 4);
    auto put = [](std::vector<uint8_t>& out, size_t i, Colour c, CGFloat alpha) {
        alpha = std::clamp<CGFloat>(alpha, 0.0, 1.0);
        out[i * 4 + 0] = (uint8_t)std::lround(std::clamp<CGFloat>(c.r, 0.0, 1.0) * alpha * 255.0);
        out[i * 4 + 1] = (uint8_t)std::lround(std::clamp<CGFloat>(c.g, 0.0, 1.0) * alpha * 255.0);
        out[i * 4 + 2] = (uint8_t)std::lround(std::clamp<CGFloat>(c.b, 0.0, 1.0) * alpha * 255.0);
        out[i * 4 + 3] = (uint8_t)std::lround(alpha * 255.0);
    };
    for (size_t i = 0; i < n; ++i) {
        const CGFloat crack = tile.crack[i] / 255.0, plate = tile.plate[i] / 255.0, glow = tile.glow[i] / 255.0;
        // Pieces of baked earth, some darker than others, split by black cracks
        const Colour earth = { kCharMid.r * (0.6 + 0.8 * plate), kCharMid.g * (0.6 + 0.8 * plate),
                               kCharMid.b * (0.6 + 0.8 * plate) };
        const CGFloat base = 0.3 + 0.45 * (1.0 - plate);
        put(scorch, i, mix(earth, kCharDark, crack), base + (0.97 - base) * crack);
        // Embers: yellow in the cracks, red around them
        put(ember, i, mix(kEmberRed, kEmberYellow, crack), std::max(crack, 0.7 * glow));
    }
    scorchTile_ = createImage(scorch, kTilePixels, kTilePixels, srgb_);
    emberTile_ = createImage(ember, kTilePixels, kTilePixels, srgb_);
    scorchRamp_ = createRamp(scorchFade);
    emberRamp_ = createRamp(emberFade);
    return scorchTile_ && emberTile_ && scorchRamp_ && emberRamp_;
}

void Painter::scorch(CGContextRef ctx, CGRect zone, CGImageRef mask, CGRect maskRect, CGFloat scale,
                     CGFloat tileOriginX, float heat, float flicker, bool screen) {
    zone = CGRectStandardize(zone);
    if (zone.size.width < 1.0 || zone.size.height <= 0.0 || !(scale > 0.0) || !makeTiles()) return;
    heat = std::clamp(heat, 0.0f, 1.0f);
    flicker = std::clamp(flicker, 0.0f, 1.0f);

    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, zone);
    if (mask) {
        // Only the waveform cracks: its silhouette, cut down to the zone so
        // the clip covers a few thousand pixels, not the whole view
        const CGRect cut = CGRectIntersection(zone, maskRect);
        const CGFloat maskW = (CGFloat)CGImageGetWidth(mask);
        const CGFloat px0 = CGRectIsEmpty(cut) ? 0.0
                          : std::max<CGFloat>(0.0, std::floor((cut.origin.x - maskRect.origin.x) * scale));
        const CGFloat px1 = CGRectIsEmpty(cut) ? 0.0
                          : std::min(maskW, std::ceil((CGRectGetMaxX(cut) - maskRect.origin.x) * scale));
        CGImageRef part = px1 > px0
            ? CGImageCreateWithImageInRect(mask, CGRectMake(px0, 0, px1 - px0, (CGFloat)CGImageGetHeight(mask)))
            : nullptr;
        if (!part) {
            CGContextRestoreGState(ctx);
            return;
        }
        CGContextClipToMask(ctx, CGRectMake(maskRect.origin.x + px0 / scale, maskRect.origin.y, (px1 - px0) / scale,
                                            maskRect.size.height), part);
        CGImageRelease(part);
    }

    const CGFloat left = zone.origin.x, right = CGRectGetMaxX(zone);
    // Charring: a dark wash, darkest at the cursor
    CGFloat comps[kGradientSteps * 4], locations[kGradientSteps];
    for (int i = 0; i < kGradientSteps; ++i) {
        const float u = (float)i / (kGradientSteps - 1);
        comps[i * 4 + 0] = kCharDark.r;
        comps[i * 4 + 1] = kCharDark.g;
        comps[i * 4 + 2] = kCharDark.b;
        comps[i * 4 + 3] = 0.55 * heat * scorchFade(u);
        locations[i] = u;
    }
    CGGradientRef wash = CGGradientCreateWithColorComponents(srgb_, comps, locations, kGradientSteps);
    if (wash) {
        CGContextDrawLinearGradient(ctx, wash, CGPointMake(right, 0), CGPointMake(left, 0), 0);
        CGGradientRelease(wash);
    }

    // The broken pieces and their cracks, fading out behind
    const CGRect tileRect = CGRectMake(tileOriginX, zone.origin.y, kTilePoints, kTilePoints);
    CGContextSaveGState(ctx);
    CGContextClipToMask(ctx, zone, scorchRamp_);
    CGContextSetAlpha(ctx, 0.4 + 0.6 * heat);
    CGContextDrawTiledImage(ctx, tileRect, scorchTile_);
    CGContextRestoreGState(ctx);

    // The freshest cracks still glow just behind the cursor
    const CGFloat emberWidth = zone.size.width * 0.7;
    if (flicker * heat > 0.0f && emberWidth >= 1.0) {
        CGContextSaveGState(ctx);
        CGContextClipToMask(ctx, CGRectMake(right - emberWidth, zone.origin.y, emberWidth, zone.size.height), emberRamp_);
        if (screen) CGContextSetBlendMode(ctx, kCGBlendModeScreen);
        CGContextSetAlpha(ctx, flicker * heat);
        CGContextDrawTiledImage(ctx, tileRect, emberTile_);
        CGContextRestoreGState(ctx);
    }
    CGContextRestoreGState(ctx);
}

void Painter::jaggedCursor(CGContextRef ctx, CGRect rect, CGFloat x, double time, float amplitude) {
    jaggedLine((float)rect.size.height, 5.0f, amplitude, time, 0x6A09E667u, line_);
    if (line_.size() < 2) return;
    CGMutablePathRef path = CGPathCreateMutable();
    for (size_t i = 0; i < line_.size(); ++i) {
        const CGPoint p = CGPointMake(x + line_[i][0], rect.origin.y + line_[i][1]);
        if (i == 0) CGPathMoveToPoint(path, nullptr, p.x, p.y);
        else CGPathAddLineToPoint(path, nullptr, p.x, p.y);
    }
    // A fissure: a glow round it, its dark broken edges, a hot core. Its own
    // colours, which read on dark and light waveforms alike.
    struct Pass { Colour colour; CGFloat alpha, width; };
    const Pass passes[] = { { kEmberRed, 0.3, 5.0 }, { kCharDark, 0.9, 2.6 }, { kEmberYellow, 1.0, 1.0 } };
    CGContextSaveGState(ctx);
    CGContextSetLineJoin(ctx, kCGLineJoinMiter);
    CGContextSetMiterLimit(ctx, 4.0);
    for (const Pass& pass : passes) {
        CGContextAddPath(ctx, path);
        stroke(ctx, srgb_, pass.colour, pass.alpha);
        CGContextSetLineWidth(ctx, pass.width);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
    CGPathRelease(path);
}

} // namespace waveseek::fx
