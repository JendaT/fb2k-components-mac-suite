//
//  CursorEffectPainter.mm
//  foo_wave_seekbar_mac
//

#include "CursorEffectPainter.h"
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstring>

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

// Fire keeps its own colours in every theme
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

void Painter::stepFire(CGRect rect, float fuel, double now) {
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
        fireHistory_.reset(cols, rows);
        // Lit, not growing from nothing, with a history for the row
        for (int i = 0; i < rows + FireHistory::kFrames; ++i) {
            fire_.step(fuel);
            fireHistory_.push(fire_);
        }
        fireClock_ = now;
    }
    fireCell_ = cell;
    // Stepped by the clock, not per frame, so extra redraws don't speed it up
    int steps = 0;
    if (fireClock_ < 0.0 || now < fireClock_ || now - fireClock_ > 0.5) {
        fireClock_ = now;
        steps = 1;
    } else {
        steps = (int)((now - fireClock_) * kFireStepsPerSecond);
        fireClock_ += steps / kFireStepsPerSecond;
    }
    for (int i = 0; i < std::min(steps, kFireMaxStepsPerFrame); ++i) {
        fire_.step(fuel);
        fireHistory_.push(fire_);
    }
}

void Painter::fireRow(CGContextRef ctx, CGRect rect, CGFloat cursorX, CGFloat trackStartX, CGFloat pixelScale,
                      const std::function<float(CGFloat)>& levelAt) {
    if (fireHistory_.count() == 0 || !(fireCell_ > 0.0) || !(pixelScale > 0.0) || !levelAt) return;
    const int width = fire_.width(), source = fire_.source();
    // Fires half as far apart as their flames are wide (the bed burns over
    // about 40 % of the field): overlapping, from different moments, they
    // make one wall with no gaps
    const CGFloat spacing = width * fireCell_ * 0.2;
    const CGFloat left = std::max(rect.origin.x, trackStartX);
    const CGFloat right = std::min(CGRectGetMaxX(rect), cursorX + (width - source) * fireCell_);
    if (!(right > left)) return;
    layoutFires(trackStartX, left, cursorX, spacing, levelAt, firePlaces_);
    if (firePlaces_.empty()) return;

    // One heat grid for the row in field cells, from a fire's reach left of
    // `left` (so the first fire shows whole) to `right`
    const CGFloat originX = left - std::max(source, width - source) * fireCell_;
    const int outW = (int)std::ceil((right - originX) / fireCell_);
    const int outH = fire_.height();
    fireColumns_.clear();
    for (const FirePlace& p : firePlaces_) {
        fireColumns_.push_back({ (int)std::lround((p.x - originX) / fireCell_), p.scale, p.width, p.heat, p.age,
                                 p.mirror });
    }
    composeFires(fireHistory_, source, fireColumns_, outW, outH, rowHeat_);

    // Only the rows that burn, top row first (image order), softened
    // sideways so the fires' beds run together
    int rows = 0;
    for (int y = outH - 1; y >= 0 && rows == 0; --y) {
        const uint8_t* row = &rowHeat_[(size_t)y * (size_t)outW];
        if (std::any_of(row, row + outW, [](uint8_t v) { return v > 24; })) rows = std::min(outH, y + 2);
    }
    if (rows == 0) return;
    rowSoft_.resize((size_t)outW * (size_t)rows);
    for (int y = 0; y < rows; ++y) {
        const uint8_t* in = &rowHeat_[(size_t)y * (size_t)outW];
        uint8_t* out = &rowSoft_[(size_t)(rows - 1 - y) * (size_t)outW];
        for (int x = 0; x < outW; ++x) {
            const int l = in[std::max(0, x - 1)], r = in[std::min(outW - 1, x + 1)];
            out[x] = (uint8_t)((l + 2 * in[x] + r + 2) / 4);
        }
    }

    // Up to the screen's pixels with vImage, then coloured: CoreGraphics
    // scaling an image this wide takes several milliseconds, drawing one at
    // its own size a fraction of that. Its left edge on a whole pixel.
    const CGFloat px0 = std::floor(originX * pixelScale);
    const size_t pxW = (size_t)std::max<long>(1, std::lround(outW * fireCell_ * pixelScale));
    const size_t pxH = (size_t)std::max<long>(1, std::lround(rows * fireCell_ * pixelScale));
    rowPixels_.resize(pxW * pxH);
    vImage_Buffer src = { rowSoft_.data(), (vImagePixelCount)rows, (vImagePixelCount)outW, (size_t)outW };
    vImage_Buffer dst = { rowPixels_.data(), (vImagePixelCount)pxH, (vImagePixelCount)pxW, pxW };
    const vImage_Error temp = vImageScale_Planar8(&src, &dst, nullptr, kvImageGetTempBufferSize);
    if (temp < 0) return;
    rowTemp_.resize((size_t)temp + 1);
    if (vImageScale_Planar8(&src, &dst, rowTemp_.data(), kvImageNoFlags) != kvImageNoError) return;
    // The palette as whole pixels, one store each
    static const std::array<uint32_t, 256> palette = [] {
        std::array<uint32_t, 256> t{};
        for (int h = 0; h < 256; ++h) std::memcpy(&t[(size_t)h], FireField::colour((uint8_t)h).data(), 4);
        return t;
    }();
    rowRgba_.resize(pxW * pxH * 4);
    uint32_t* out = reinterpret_cast<uint32_t*>(rowRgba_.data());
    for (size_t i = 0; i < pxW * pxH; ++i) out[i] = palette[rowPixels_[i]];
    CGImageRef image = createImage(rowRgba_, (int)pxW, (int)pxH, srgb_);
    if (!image) return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationNone);
    CGContextDrawImage(ctx, CGRectMake(px0 / pixelScale, rect.origin.y, pxW / pixelScale, pxH / pixelScale), image);
    CGContextRestoreGState(ctx);
    CGImageRelease(image);
}

void Painter::fireWall(CGContextRef ctx, CGRect rect, CGFloat x) {
    if (fire_.empty() || !(fireCell_ > 0.0)) return;
    const int cols = fire_.width(), rows = fire_.height(), source = fire_.source();
    fireRgba_.resize((size_t)cols * (size_t)rows * 4);
    fire_.paint(fireRgba_.data(), (size_t)cols * 4);
    CGImageRef image = createImage(fireRgba_, cols, rows, srgb_);
    if (!image) return;
    CGContextSaveGState(ctx);
    CGContextClipToRect(ctx, rect);
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(x - (source + 0.5) * fireCell_, rect.origin.y, cols * fireCell_,
                                       rows * fireCell_), image);
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

// The crack pattern and the ramps once; the tiles' colours again when the
// theme's change
bool Painter::makeTiles(const EarthColours& colours) {
    if (!crackTried_) {
        crackTried_ = true;
        crackTile_ = makeCrackTile(kTilePixels, kTileCells, 0x3C6EF372u);
        scorchRamp_ = createRamp(scorchFade);
        emberRamp_ = createRamp(emberFade);
    }
    if (crackTile_.size != kTilePixels || !scorchRamp_ || !emberRamp_) return false;
    if (scorchTile_ && emberTile_ && colours == tileColours_) return true;
    CGImageRelease(scorchTile_);
    CGImageRelease(emberTile_);
    tileColours_ = colours;
    const CrackTile& tile = crackTile_;
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
        // Baked pieces of the wave, some darker than others, split by
        // nearly black cracks
        const CGFloat shade = 0.6 + 0.8 * plate;
        const Colour piece = { colours.plate.r * shade, colours.plate.g * shade, colours.plate.b * shade };
        const CGFloat base = 0.3 + 0.45 * (1.0 - plate);
        put(scorch, i, mix(piece, colours.crack, crack), base + (0.97 - base) * crack);
        // Embers: the hot core in the cracks, the glow round them
        put(ember, i, mix(colours.ember, colours.core, crack), std::max(crack, 0.7 * glow));
    }
    scorchTile_ = createImage(scorch, kTilePixels, kTilePixels, space_);
    emberTile_ = createImage(ember, kTilePixels, kTilePixels, space_);
    return scorchTile_ && emberTile_;
}

void Painter::scorch(CGContextRef ctx, CGRect zone, CGImageRef mask, CGRect maskRect, CGFloat scale,
                     CGFloat tileOriginX, float heat, float flicker, const EarthColours& colours, bool screen) {
    zone = CGRectStandardize(zone);
    if (zone.size.width < 1.0 || zone.size.height <= 0.0 || !(scale > 0.0) || !makeTiles(colours)) return;
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
    // Charring: a wash of the crack colour, darkest at the cursor
    CGFloat comps[kGradientSteps * 4], locations[kGradientSteps];
    for (int i = 0; i < kGradientSteps; ++i) {
        const float u = (float)i / (kGradientSteps - 1);
        comps[i * 4 + 0] = colours.crack.r;
        comps[i * 4 + 1] = colours.crack.g;
        comps[i * 4 + 2] = colours.crack.b;
        comps[i * 4 + 3] = 0.55 * heat * scorchFade(u);
        locations[i] = u;
    }
    CGGradientRef wash = CGGradientCreateWithColorComponents(space_, comps, locations, kGradientSteps);
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

void Painter::jaggedCursor(CGContextRef ctx, CGRect rect, CGFloat x, double time, float amplitude,
                           const EarthColours& colours) {
    jaggedLine((float)rect.size.height, 5.0f, amplitude, time, 0x6A09E667u, line_);
    if (line_.size() < 2) return;
    CGMutablePathRef path = CGPathCreateMutable();
    for (size_t i = 0; i < line_.size(); ++i) {
        const CGPoint p = CGPointMake(x + line_[i][0], rect.origin.y + line_[i][1]);
        if (i == 0) CGPathMoveToPoint(path, nullptr, p.x, p.y);
        else CGPathAddLineToPoint(path, nullptr, p.x, p.y);
    }
    // A fissure: a glow round it, its dark broken edges, a hot core; the
    // dark edges keep the light core legible on a light background too
    struct Pass { Colour colour; CGFloat alpha, width; };
    const Pass passes[] = { { colours.ember, 0.35, 5.0 }, { colours.crack, 0.9, 2.6 }, { colours.core, 1.0, 1.0 } };
    CGContextSaveGState(ctx);
    CGContextSetLineJoin(ctx, kCGLineJoinMiter);
    CGContextSetMiterLimit(ctx, 4.0);
    for (const Pass& pass : passes) {
        CGContextAddPath(ctx, path);
        stroke(ctx, space_, pass.colour, pass.alpha);
        CGContextSetLineWidth(ctx, pass.width);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);
    CGPathRelease(path);
}

} // namespace waveseek::fx
