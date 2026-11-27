//
//  MeterPreview.mm
//  foo_jl_levelmeter_mac
//
//  Renders the meter to PNG files without foobar2000, for checking the
//  design. Feeds a few seconds of synthetic music-like audio through the
//  real engine, then draws a set of panel sizes and styles.
//
//  Build and run: Scripts/preview.sh [output-dir]
//
//  Also: Scripts/preview.sh --stack   (the Static, Live and Overlay layers
//        composited must match one Pass::All draw)
//        Scripts/preview.sh --time    (ms per frame of each pass at 2x)
//

#import <Cocoa/Cocoa.h>
#include "../src/Core/MeterEngine.h"
#include "../src/Core/LevelMeterThemes.h"
#include "../src/UI/MeterRenderer.h"
#include <chrono>
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

using namespace meter;

namespace {

// Kick-and-chord loop with some stereo spread, peaking near -1 dBFS.
void feedMusic(MeterEngine &e, double seconds) {
    const double sr = 48000.0, kPi = 3.14159265358979323846;
    const size_t perFrame = 800;
    std::vector<float> buf(perFrame * 2);
    size_t n = 0;
    for (int f = 0; f < (int)(seconds * 60); ++f) {
        for (size_t i = 0; i < perFrame; ++i, ++n) {
            const double t = n / sr;
            const double beat = std::fmod(t, 0.5);
            const double kick = 0.75 * std::exp(-beat * 18.0) * std::sin(2 * kPi * (50 + 80 * std::exp(-beat * 30)) * beat);
            const double pad = 0.12 * (std::sin(2 * kPi * 220 * t) + 0.7 * std::sin(2 * kPi * 277.2 * t) +
                                       0.5 * std::sin(2 * kPi * 329.6 * t));
            const double hat = 0.05 * std::sin(2 * kPi * 7919 * t) * std::exp(-std::fmod(t, 0.25) * 60.0);
            buf[2 * i] = (float)(kick + pad * 1.05 + hat);
            buf[2 * i + 1] = (float)(kick + pad * 0.85 - hat * 0.6 + 0.04 * std::sin(2 * kPi * 330.1 * t));
        }
        e.process(buf.data(), perFrame, sr, 2);
        e.advance(1.0 / 60.0);
    }
}

Palette darkPalette() { return Palette(); }

Palette lightPalette() {
    Palette p;
    p.background = 0xFFF4F4F4;
    p.text = 0xFF30353B;
    p.safe = 0xFF1B8A3A;
    p.warn = 0xFFB86A00;
    p.over = 0xFFD70015;
    p.loudness = 0xFF2E7DD1;
    p.dark = false;
    return p;
}

void render(const std::string &path, CGFloat w, CGFloat h, const DisplaySettings &s, const Snapshot &snap) {
    const CGFloat scale = 2.0;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
        pixelsWide:(NSInteger)(w * scale) pixelsHigh:(NSInteger)(h * scale) bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = NSMakeSize(w, h);
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    // The rep's point size already maps points to pixels; flip to a
    // top-left origin like the view.
    CGContextRef ctx = gc.CGContext;
    CGContextTranslateCTM(ctx, 0, h);
    CGContextScaleCTM(ctx, 1, -1);
    NSGraphicsContext *flipped = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:flipped];
    MeterRenderer r;
    r.draw(ctx, CGRectMake(0, 0, w, h), s, snap);
    [NSGraphicsContext restoreGraphicsState];
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    [png writeToFile:[NSString stringWithUTF8String:path.c_str()] atomically:YES];
    printf("wrote %s\n", path.c_str());
}

#pragma mark - Layer checks and timing

// Transparent premultiplied bitmap at 2x, top-left origin like the view's
// layers; 8-bit like a layer's backing, or float. Caller releases.
CGContextRef makeContext(CGFloat w, CGFloat h, bool floatPixels = false, CGFloat scale = 2.0) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = floatPixels
        ? CGBitmapContextCreate(NULL, (size_t)(w * scale), (size_t)(h * scale), 32, 0, space,
                                kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents | kCGBitmapByteOrder32Little)
        : CGBitmapContextCreate(NULL, (size_t)(w * scale), (size_t)(h * scale), 8, 0, space,
                                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(space);
    CGContextClearRect(ctx, CGRectMake(0, 0, w * scale, h * scale));
    CGContextTranslateCTM(ctx, 0, h * scale);
    CGContextScaleCTM(ctx, scale, -scale);
    return ctx;
}

// Run `body` with `ctx` as the current (flipped) AppKit context, for the text.
template <typename F>
void withContext(CGContextRef ctx, F body) {
    NSGraphicsContext *gc = [NSGraphicsContext graphicsContextWithCGContext:ctx flipped:YES];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:gc];
    body();
    [NSGraphicsContext restoreGraphicsState];
}

// Draw Static, Live and Overlay into separate layers, stack them the way
// the view does and compare with one Pass::All draw. Returns the largest
// difference in any channel, in 1/255 steps.
int stackDiff(CGFloat w, CGFloat h, const DisplaySettings &s, const Snapshot &snap, bool floatPixels) {
    const CGRect bounds = CGRectMake(0, 0, w, h);
    MeterRenderer r;
    CGContextRef all = makeContext(w, h, floatPixels);
    withContext(all, [&] { r.draw(all, bounds, s, snap, Pass::All); });
    const Pass passes[3] = { Pass::Static, Pass::Live, Pass::Overlay };
    CGContextRef stacked = makeContext(w, h, floatPixels);
    CGContextSaveGState(stacked);
    CGContextConcatCTM(stacked, CGAffineTransformInvert(CGContextGetCTM(stacked)));
    const CGRect px = CGRectMake(0, 0, CGBitmapContextGetWidth(stacked), CGBitmapContextGetHeight(stacked));
    for (Pass pass : passes) {
        CGContextRef layer = makeContext(w, h, floatPixels);
        withContext(layer, [&] { r.draw(layer, bounds, s, snap, pass); });
        CGImageRef img = CGBitmapContextCreateImage(layer);
        CGContextDrawImage(stacked, px, img);
        CGImageRelease(img);
        CGContextRelease(layer);
    }
    CGContextRestoreGState(stacked);
    const size_t bytes = CGBitmapContextGetBytesPerRow(all) * CGBitmapContextGetHeight(all);
    double maxDiff = 0;
    if (floatPixels) {
        const float *a = (const float *)CGBitmapContextGetData(all), *b = (const float *)CGBitmapContextGetData(stacked);
        for (size_t i = 0; i < bytes / sizeof(float); ++i) maxDiff = std::max(maxDiff, std::fabs((double)a[i] - b[i]) * 255.0);
    } else {
        const uint8_t *a = (const uint8_t *)CGBitmapContextGetData(all), *b = (const uint8_t *)CGBitmapContextGetData(stacked);
        for (size_t i = 0; i < bytes; ++i) maxDiff = std::max(maxDiff, (double)std::abs((int)a[i] - (int)b[i]));
    }
    CGContextRelease(all);
    CGContextRelease(stacked);
    return (int)std::ceil(maxDiff - 1e-3);
}

// Float pixels show whether the layers add up to the same picture; 8-bit
// layers (as on screen) also round each layer, a step or two at most.
int stackCheck(const char *name, CGFloat w, CGFloat h, const DisplaySettings &s, const Snapshot &snap) {
    const int exact = stackDiff(w, h, s, snap, true);
    const int eightBit = stackDiff(w, h, s, snap, false);
    printf("%-24s max channel difference: float %d, 8-bit %d\n", name, exact, eightBit);
    return exact;
}

// Needles swinging and the LED blinking, so each frame draws something new.
Snapshot movingSnapshot(const Snapshot &base, int frame) {
    Snapshot s = base;
    for (int c = 0; c < 2; ++c) {
        const double v = 0.5 + 0.5 * std::sin(frame * 0.07 + c * 1.3);
        s.ch[c].needleDb = (float)(-20.0 + 23.0 * v);
        s.ch[c].peakDb = (float)(-12.0 + 12.5 * v);
        s.ch[c].rmsDb = s.ch[c].peakDb - 8.0f;
        s.ch[c].holdDb = s.ch[c].peakDb + 1.0f;
    }
    return s;
}

// Mean ms per frame of `pass`, cleared each frame like a layer's backing.
double timePass(CGFloat w, CGFloat h, const DisplaySettings &s, const Snapshot &base, Pass pass, int frames) {
    const CGRect bounds = CGRectMake(0, 0, w, h);
    MeterRenderer r;
    CGContextRef ctx = makeContext(w, h);
    double ms = 0;
    withContext(ctx, [&] {
        for (int f = -20; f < frames; ++f) {   // a few frames of warm-up (font caches)
            const Snapshot snap = movingSnapshot(base, f);
            const auto t0 = std::chrono::steady_clock::now();
            @autoreleasepool {
                CGContextClearRect(ctx, bounds);
                r.draw(ctx, bounds, s, snap, pass);
            }
            const auto t1 = std::chrono::steady_clock::now();
            if (f >= 0) ms += std::chrono::duration<double, std::milli>(t1 - t0).count();
        }
    });
    CGContextRelease(ctx);
    return ms / frames;
}

void timeCase(const char *name, CGFloat w, CGFloat h, const DisplaySettings &s, const Snapshot &base) {
    const int frames = 600;
    const double all = timePass(w, h, s, base, Pass::All, frames);
    const double st = timePass(w, h, s, base, Pass::Static, frames);
    const double live = timePass(w, h, s, base, Pass::Live, frames);
    const double ov = timePass(w, h, s, base, Pass::Overlay, frames);
    printf("%-26s %4.0fx%-4.0f  all %6.3f  static %6.3f  live %6.3f  overlay %6.3f  ms\n", name, w, h, all, st, live,
           ov);
}

} // namespace

int main(int argc, const char **argv) {
    @autoreleasepool {
        const std::string out = argc > 1 ? argv[1] : ".";
        const bool stack = out == "--stack", timing = out == "--time";
        MeterEngine e;
        e.configure(EngineSettings());
        feedMusic(e, 6.0);
        Snapshot snap = e.snapshot();

        if (stack || timing) {
            DisplaySettings d;
            d.palette = darkPalette();
            DisplaySettings a = d;
            a.style = MeterStyle::Analog;
            Snapshot lit = snap, unlit = snap;
            lit.ch[0].peakDb = lit.ch[1].peakDb = -0.2f;
            unlit.ch[0].peakDb = unlit.ch[1].peakDb = -6.0f;
            Snapshot mono = lit;
            mono.channels = 1;
            mono.ch[1] = mono.ch[0];
            if (stack) {
                int worst = 0;
                auto check = [&](const char *name, CGFloat w, CGFloat h, const DisplaySettings &s, const Snapshot &sn) {
                    worst = std::max(worst, stackCheck(name, w, h, s, sn));
                };
                const FaceStyle faces[3] = { FaceStyle::Vintage, FaceStyle::Dark, FaceStyle::Theme };
                const char *faceNames[3] = { "vintage", "dark", "theme" };
                for (int i = 0; i < 3; ++i) {
                    DisplaySettings f = a;
                    f.face = faces[i];
                    std::string base = faceNames[i];
                    check((base + " pair lit").c_str(), 560, 200, f, lit);
                    check((base + " pair unlit").c_str(), 560, 200, f, unlit);
                    check((base + " stacked lit").c_str(), 260, 380, f, lit);
                    check((base + " mono").c_str(), 560, 200, f, mono);
                    DisplaySettings one = f;
                    one.needleLayout = NeedleLayout::Single;
                    check((base + " single lit").c_str(), 320, 210, one, lit);
                    check((base + " single unlit").c_str(), 320, 210, one, unlit);
                }
                DisplaySettings ppm = a;
                ppm.needle = NeedleBallistics::PpmDin;
                ppm.peakLed = false;
                check("vintage ppm no led", 560, 200, ppm, snap);
                DisplaySettings clear = a;
                clear.face = FaceStyle::Theme;
                clear.palette = lightPalette();
                clear.palette.background = 0x00000000;
                check("theme light clear bg", 560, 200, clear, lit);
                check("analog too small", 60, 30, a, lit);
                check("digital vertical", 260, 420, d, snap);
                check("digital horizontal", 760, 104, d, snap);
                printf("worst %d\n", worst);
                return worst <= 1 ? 0 : 1;
            }
            printf("ms per frame at 2x, %d frames each\n", 600);
            timeCase("digital", 260, 420, d, snap);
            timeCase("digital horizontal", 760, 104, d, snap);
            const FaceStyle faces[3] = { FaceStyle::Vintage, FaceStyle::Dark, FaceStyle::Theme };
            const char *faceNames[3] = { "vintage", "dark", "theme" };
            for (int i = 0; i < 3; ++i) {
                DisplaySettings f = a;
                f.face = faces[i];
                timeCase((std::string(faceNames[i]) + " pair").c_str(), 560, 200, f, snap);
                timeCase((std::string(faceNames[i]) + " pair large").c_str(), 1000, 360, f, snap);
            }
            DisplaySettings one = a;
            one.needleLayout = NeedleLayout::Single;
            timeCase("vintage single", 320, 210, one, snap);
            timeCase("vintage stacked", 260, 380, a, snap);
            return 0;
        }
        // Show a latched clip on one side so its look gets checked too.
        Snapshot clipped = snap;
        clipped.ch[1].clip = true;
        clipped.ch[1].maxDb = 0.4f;

        DisplaySettings d;
        d.palette = darkPalette();
        render(out + "/digital_vertical_dark.png", 260, 420, d, clipped);
        render(out + "/digital_horizontal_dark.png", 760, 104, d, snap);
        render(out + "/digital_small_dark.png", 120, 200, d, snap);

        DisplaySettings seg = d;
        seg.segments = true;
        seg.scale = ScaleType::K14;
        seg.barMode = BarMode::PeakAndRms;
        render(out + "/digital_k14_segments.png", 260, 420, seg, snap);

        // A shipped theme, dark colours, as the component would load it.
        DisplaySettings amber = d;
        for (int i = 0; i < kMeterThemeCount; ++i) {
            if (std::string(kMeterThemes[i].name) != "P3 amber") continue;
            const uint32_t *c = kMeterThemes[i].dark;
            amber.palette.background = c[0]; amber.palette.text = c[1]; amber.palette.safe = c[2];
            amber.palette.warn = c[3]; amber.palette.over = c[4]; amber.palette.loudness = c[5];
        }
        amber.segments = true;
        render(out + "/digital_p3_amber.png", 260, 420, amber, clipped);

        DisplaySettings big = d;
        big.textScale = 1.4;
        render(out + "/digital_text_large.png", 260, 420, big, clipped);
        render(out + "/digital_text_large_horizontal.png", 760, 120, big, snap);

        DisplaySettings deep = d;
        deep.floorDb = -120;
        render(out + "/digital_range_120.png", 260, 420, deep, snap);

        DisplaySettings light = d;
        light.palette = lightPalette();
        render(out + "/digital_vertical_light.png", 260, 420, light, snap);
        render(out + "/digital_horizontal_light.png", 760, 104, light, clipped);

        DisplaySettings a = d;
        a.style = MeterStyle::Analog;
        render(out + "/analog_pair_vintage.png", 560, 200, a, snap);
        a.face = FaceStyle::Dark;
        render(out + "/analog_pair_dark.png", 560, 200, a, snap);
        a.face = FaceStyle::Vintage;
        a.needleLayout = NeedleLayout::Single;
        render(out + "/analog_single_vintage.png", 320, 210, a, snap);
        a.face = FaceStyle::Theme;
        a.needleLayout = NeedleLayout::Auto;
        render(out + "/analog_stacked_theme.png", 260, 380, a, snap);
    }
    return 0;
}
