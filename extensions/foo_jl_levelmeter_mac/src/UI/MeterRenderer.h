//
//  MeterRenderer.h
//  foo_jl_levelmeter_mac
//
//  Draws the meter into the current NSGraphicsContext. Needs no SDK, so the
//  preview tool can render it to images. Coordinates are top-left origin:
//  call it from a flipped view (or a flipped context).
//

#pragma once

#import <Cocoa/Cocoa.h>
#include "../Core/DisplaySettings.h"
#include "../Core/MeterEngine.h"
#include "../Core/MeterLayout.h"

namespace meter {

// Which part of the meter a click landed on.
enum class HitArea {
    None,
    Peaks,      // readouts, clip lights, level bars: reset maxima
    Loudness,   // loudness bars and figures: reset the measurement
};

class MeterRenderer {
public:
    // Draw everything inside `bounds`.
    void draw(CGContextRef ctx, CGRect bounds, const DisplaySettings &s, const Snapshot &snap);

    // What a click at `p` would reset (uses the last layout drawn).
    HitArea hitTest(CGPoint p) const;

private:
    void drawDigital(CGContextRef ctx, CGRect bounds, const DisplaySettings &s, const Snapshot &snap);
    void drawAnalog(CGContextRef ctx, CGRect bounds, const DisplaySettings &s, const Snapshot &snap);

    meter_layout::Result _layout;
    bool _analog = false;
    CGRect _bounds = CGRectZero;
};

} // namespace meter
