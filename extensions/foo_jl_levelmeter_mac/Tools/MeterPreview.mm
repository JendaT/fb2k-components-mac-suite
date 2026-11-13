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

#import <Cocoa/Cocoa.h>
#include "../src/Core/MeterEngine.h"
#include "../src/Core/LevelMeterThemes.h"
#include "../src/UI/MeterRenderer.h"
#include <cmath>
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

} // namespace

int main(int argc, const char **argv) {
    @autoreleasepool {
        const std::string out = argc > 1 ? argv[1] : ".";
        MeterEngine e;
        e.configure(EngineSettings());
        feedMusic(e, 6.0);
        Snapshot snap = e.snapshot();
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
