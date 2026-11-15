//
//  CursorEffectPainter.h
//  foo_wave_seekbar_mac
//
//  CoreGraphics drawing for the cursor effects built on CursorFx.h (Glow,
//  Particles, Firewall, Earthcrusher), and the images they keep: the fire
//  field's frame, the crack tiles, the fade ramps. The view works out the
//  geometry and colours and calls in here. No AppKit, so a harness can draw
//  the same frames into a bitmap.
//

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include "../Core/CursorFx.h"
#include <array>
#include <functional>
#include <vector>

namespace waveseek::fx {

struct Colour {
    CGFloat r = 0, g = 0, b = 0;
    bool operator==(const Colour& o) const { return r == o.r && g == o.g && b == o.b; }
};

// Earthcrusher's colours (EarthShades in the view's theme space)
struct EarthColours {
    Colour plate, crack, clod, ember, core;
    bool operator==(const EarthColours& o) const {
        return plate == o.plate && crack == o.crack && clod == o.clod && ember == o.ember && core == o.core;
    }
};

// Where the sparks go: the cursor's x at a playback time, and how far the
// waveform reaches above and below a lane's centre at an x (points)
struct SparkGeometry {
    int lanes = 1;
    CGFloat centre[2] = { 0, 0 };
    CGFloat amplitude = 0;      // a lane's half height
    std::function<CGFloat(double)> xAt;
    std::function<void(CGFloat x, int lane, CGFloat& top, CGFloat& bottom)> edges;
};

class Painter {
public:
    // Colours are in `space` (the view's theme space), the crack tiles too;
    // the fire is sRGB
    explicit Painter(CGColorSpaceRef space);
    ~Painter();
    Painter(const Painter&) = delete;
    Painter& operator=(const Painter&) = delete;

    // A bloom centred on the cursor line at x over the full height of
    // `bounds`: `halo` fading with distance, a thin `core` at the line.
    // `pulse` 0..1 widens and brightens it; `strength` scales it all,
    // `coreShare` the core alone. `screen` (on a dark background) lightens
    // what is under it instead of painting over it.
    void glow(CGContextRef ctx, CGRect bounds, CGFloat x, Colour halo, Colour core, float pulse,
              float strength, bool screen, float coreShare = 1.0f);

    // Sparks off the waveform: fresh hot ones in `hot`, the rest in `cool`;
    // `screen` as for glow
    void sparks(CGContextRef ctx, const std::vector<Spark>& sparks, const SparkGeometry& geometry,
                Colour hot, Colour cool, bool screen);

    // Firewall: steps the fire for a view `rect`'s height by `wallTime`
    // (seconds), fed by `fuel` (FireField::step). Once a frame, before the
    // two below.
    void stepFire(CGRect rect, float fuel, double wallTime);
    // The row of fires along the played part, in `rect` up to the cursor at
    // `cursorX`, anchored at the track's start `trackStartX`, each as tall
    // as `levelAt(x)` (0..1) and the nearness of the cursor have it.
    // `pixelScale`: device pixels per point, for drawing it pixel for pixel.
    void fireRow(CGContextRef ctx, CGRect rect, CGFloat cursorX, CGFloat trackStartX, CGFloat pixelScale,
                 const std::function<float(CGFloat)>& levelAt);
    // The cursor's own fire, the tallest, standing on the line at x
    void fireWall(CGContextRef ctx, CGRect rect, CGFloat x);
    // Embers rising off the wall: `born` x from xAt, heights over `rect`
    void embers(CGContextRef ctx, const std::vector<Spark>& embers, CGRect rect,
                const std::function<CGFloat(double)>& xAt, bool screen);

    // Earthcrusher's scorched, cracked waveform in `zone` (its right edge at
    // the cursor). `waveMask`: the waveform's silhouette (grey, white shows)
    // drawn over `maskRect`, `pixelScale` pixels per point; null to scorch
    // the whole zone. The cracks are anchored at `tileOriginX` so they stay
    // put on the waveform while the zone moves along it. `heat` 0..1 is how
    // fresh it looks, `flicker` 0..1 the embers' brightness now; `screen`
    // as for glow, for the embers.
    void scorch(CGContextRef ctx, CGRect zone, CGImageRef waveMask, CGRect maskRect, CGFloat pixelScale,
                CGFloat tileOriginX, float heat, float flicker, const EarthColours& colours, bool screen);
    // Earthcrusher's cursor: a jagged, glowing fissure at x over the height
    // of `rect`, morphing with `time`, within +-amplitude points
    void jaggedCursor(CGContextRef ctx, CGRect rect, CGFloat x, double time, float amplitude,
                      const EarthColours& colours);

private:
    void setFill(CGContextRef ctx, Colour c, CGFloat alpha);
    bool makeTiles(const EarthColours& colours);

    CGColorSpaceRef space_ = nullptr;
    CGColorSpaceRef srgb_ = nullptr;

    FireField fire_;
    FireHistory fireHistory_;
    CGFloat fireCell_ = 0.0;        // points a field cell covers
    std::vector<uint8_t> fireRgba_;
    double fireClock_ = -1.0;
    std::vector<FirePlace> firePlaces_;
    std::vector<FireColumn> fireColumns_;
    std::vector<uint8_t> rowHeat_, rowSoft_, rowPixels_, rowTemp_, rowRgba_;

    bool crackTried_ = false;
    CrackTile crackTile_;
    EarthColours tileColours_;
    CGImageRef scorchTile_ = nullptr;
    CGImageRef emberTile_ = nullptr;
    CGImageRef scorchRamp_ = nullptr;
    CGImageRef emberRamp_ = nullptr;

    std::vector<std::array<float, 2>> line_;
};

} // namespace waveseek::fx
