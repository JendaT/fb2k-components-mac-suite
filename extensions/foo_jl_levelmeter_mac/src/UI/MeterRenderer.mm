//
//  MeterRenderer.mm
//  foo_jl_levelmeter_mac
//

#import "MeterRenderer.h"
#include "../Core/MeterScale.h"
#include "../../../../shared/ThemeColor.h"
#include <algorithm>
#include <cmath>

using namespace meter_layout;

namespace meter {

namespace {

const double kPi = 3.14159265358979323846;

NSColor *color(uint32_t argb, CGFloat alphaScale = 1.0) {
    NSColor *c = JLColorFromARGB(argb);
    return alphaScale == 1.0 ? c : [c colorWithAlphaComponent:c.alphaComponent * alphaScale];
}

CGColorRef cg(uint32_t argb, CGFloat alphaScale = 1.0) {
    return color(argb, alphaScale).CGColor;
}

CGRect toCG(const meter_layout::Rect &r) { return CGRectMake(r.x, r.y, r.w, r.h); }

NSFont *monoFont(CGFloat size, NSFontWeight weight = NSFontWeightRegular) {
    return [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
}

// Text drawn centred / aligned in a box, shrinking the font to fit its width.
enum class Align { Left, Centre, Right };

void drawText(NSString *text, CGRect box, NSFont *font, NSColor *fg, Align align = Align::Centre) {
    if (box.size.width <= 0 || text.length == 0) return;
    NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: fg };
    NSSize sz = [text sizeWithAttributes:attrs];
    if (sz.width > box.size.width && sz.width > 0) {
        const CGFloat size = std::max(6.0, font.pointSize * box.size.width / sz.width);
        NSFont *smaller = [NSFont fontWithDescriptor:font.fontDescriptor size:size];
        attrs = @{ NSFontAttributeName: smaller ?: font, NSForegroundColorAttributeName: fg };
        sz = [text sizeWithAttributes:attrs];
    }
    CGFloat x = box.origin.x;
    if (align == Align::Centre) x += (box.size.width - sz.width) / 2.0;
    else if (align == Align::Right) x += box.size.width - sz.width;
    const CGFloat y = box.origin.y + (box.size.height - sz.height) / 2.0;
    [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
}

NSString *formatDb(double db, double floor = -99.0) {
    if (!std::isfinite(db) || db <= floor) return @"–";
    if (std::fabs(db) < 0.05) return @"0.0";
    return [NSString stringWithFormat:@"%.1f", db];
}

void fillRounded(CGContextRef ctx, CGRect r, CGFloat radius, CGColorRef c) {
    if (r.size.width <= 0 || r.size.height <= 0) return;
    radius = std::min({ radius, r.size.width / 2.0, r.size.height / 2.0 });
    CGPathRef p = CGPathCreateWithRoundedRect(r, radius, radius, NULL);
    CGContextSetFillColorWithColor(ctx, c);
    CGContextAddPath(ctx, p);
    CGContextFillPath(ctx);
    CGPathRelease(p);
}

#pragma mark - Bars

struct Zones {
    double warnPos, overPos;   // 0..1 along the bar
    uint32_t safe, warn, over;
};

// The part of `bar` from position a to b (0 = floor end, 1 = top end).
CGRect slice(CGRect bar, bool vertical, double a, double b) {
    a = std::max(0.0, std::min(1.0, a));
    b = std::max(0.0, std::min(1.0, b));
    if (b <= a) return CGRectNull;
    if (vertical) {
        const CGFloat len = bar.size.height;
        return CGRectMake(bar.origin.x, CGRectGetMaxY(bar) - b * len, bar.size.width, (b - a) * len);
    }
    const CGFloat len = bar.size.width;
    return CGRectMake(bar.origin.x + a * len, bar.origin.y, (b - a) * len, bar.size.height);
}

// Fill positions a..b of the bar in zone colours.
void fillZones(CGContextRef ctx, CGRect bar, bool vertical, double a, double b, const Zones &z, CGFloat alpha) {
    const double edges[4] = { 0.0, z.warnPos, z.overPos, 1.0 };
    const uint32_t colors[3] = { z.safe, z.warn, z.over };
    for (int i = 0; i < 3; ++i) {
        const double lo = std::max(a, edges[i]), hi = std::min(b, edges[i + 1]);
        if (hi <= lo) continue;
        CGRect r = slice(bar, vertical, lo, hi);
        if (CGRectIsNull(r)) continue;
        CGContextSetFillColorWithColor(ctx, cg(colors[i], alpha));
        CGContextFillRect(ctx, r);
    }
}

uint32_t zoneColor(double pos, const Zones &z) {
    return pos >= z.overPos ? z.over : (pos >= z.warnPos ? z.warn : z.safe);
}

// Thin line across the bar at `pos`.
void drawMarker(CGContextRef ctx, CGRect bar, bool vertical, double pos, CGFloat thickness, CGColorRef c) {
    pos = std::max(0.0, std::min(1.0, pos));
    CGRect r;
    if (vertical) {
        const CGFloat y = CGRectGetMaxY(bar) - pos * bar.size.height;
        r = CGRectMake(bar.origin.x, std::min(CGRectGetMaxY(bar) - thickness, std::max(bar.origin.y, y - thickness / 2.0)),
                       bar.size.width, thickness);
    } else {
        const CGFloat x = bar.origin.x + pos * bar.size.width;
        r = CGRectMake(std::min(CGRectGetMaxX(bar) - thickness, std::max(bar.origin.x, x - thickness / 2.0)),
                       bar.origin.y, thickness, bar.size.height);
    }
    CGContextSetFillColorWithColor(ctx, c);
    CGContextFillRect(ctx, r);
}

// LED look: background-coloured gaps across the bar every few points.
void drawSegmentGaps(CGContextRef ctx, CGRect bar, bool vertical, CGColorRef bg) {
    const CGFloat period = 4.0, gap = 1.0;
    CGContextSetFillColorWithColor(ctx, bg);
    if (vertical) {
        for (CGFloat y = CGRectGetMaxY(bar) - period; y > bar.origin.y; y -= period) {
            CGContextFillRect(ctx, CGRectMake(bar.origin.x, y, bar.size.width, gap));
        }
    } else {
        for (CGFloat x = bar.origin.x + period; x < CGRectGetMaxX(bar); x += period) {
            CGContextFillRect(ctx, CGRectMake(x - gap, bar.origin.y, gap, bar.size.height));
        }
    }
}

struct BarValues {
    double solid;      // dB: the main fill
    double light;      // dB: lighter extension above it (peak over RMS); <= solid for none
    double hold;       // dB: marker; floor for none
};

void drawBar(CGContextRef ctx, CGRect bar, bool vertical, const BarScale &scale, const BarValues &v,
             const Zones &z, const DisplaySettings &s) {
    const Palette &p = s.palette;
    CGContextSaveGState(ctx);
    CGPathRef clip = CGPathCreateWithRoundedRect(bar, 1.5, 1.5, NULL);
    CGContextAddPath(ctx, clip);
    CGContextClip(ctx);
    CGPathRelease(clip);

    CGContextSetFillColorWithColor(ctx, cg(p.text, p.dark ? 0.07 : 0.09));
    CGContextFillRect(ctx, bar);

    const double solid = scale.position(v.solid);
    const double light = scale.position(v.light);
    if (light > solid) {
        // Peak above the RMS: a faint full-width tint plus a slim column in
        // full colour down the middle, so both readings stay distinct.
        const CGRect column = vertical ? CGRectInset(bar, std::floor(bar.size.width * 0.32), 0)
                                       : CGRectInset(bar, 0, std::floor(bar.size.height * 0.32));
        fillZones(ctx, bar, vertical, solid, light, z, 0.14);
        fillZones(ctx, column, vertical, solid, light, z, 1.0);
    }
    if (solid > 0) {
        fillZones(ctx, bar, vertical, 0.0, solid, z, 1.0);
        // Brighter leading edge so the level reads crisply.
        drawMarker(ctx, bar, vertical, solid, 1.0, cg(zoneColor(solid, z), 1.0));
    }
    if (s.segments) drawSegmentGaps(ctx, bar, vertical, cg(p.background | 0xFF000000u));
    const double hold = scale.position(v.hold);
    if (hold > 0 && hold >= std::max(solid, light) - 1e-6) {
        drawMarker(ctx, bar, vertical, hold, 2.0, cg(zoneColor(hold, z)));
    }
    CGContextRestoreGState(ctx);
}

void drawScaleTicks(CGContextRef ctx, CGRect area, bool vertical, const BarScale &scale,
                    const DisplaySettings &s, bool bothSides) {
    const CGFloat ts = s.textScale;
    NSFont *font = monoFont(8.5 * ts);
    NSColor *fg = color(s.palette.text, 0.62);
    const double length = vertical ? area.size.height : area.size.width;
    const double labelPx = (vertical ? 12.0 : 26.0) * ts;
    CGContextSetFillColorWithColor(ctx, cg(s.palette.text, 0.35));
    // End labels are pulled inside the scale; skip any that would then
    // overlap the label drawn before them.
    CGRect lastLabel = CGRectNull;
    auto place = [&](CGRect box) {
        const CGRect text = vertical ? CGRectInset(box, 0, 1) : CGRectInset(box, 3, 0);
        if (!CGRectIsNull(lastLabel) && CGRectIntersectsRect(text, lastLabel)) return false;
        lastLabel = text;
        return true;
    };
    for (const BarScale::Tick &t : scale.ticks(length, labelPx)) {
        NSString *label = t.label > 0 ? [NSString stringWithFormat:@"+%d", t.label]
                                      : [NSString stringWithFormat:@"%d", t.label];
        if (vertical) {
            const CGFloat y = std::round(CGRectGetMaxY(area) - t.pos * length);
            const CGFloat tick = t.major ? 3.0 : 2.0;
            CGContextFillRect(ctx, CGRectMake(area.origin.x, y - 0.5, tick, 1.0));
            if (bothSides) CGContextFillRect(ctx, CGRectMake(CGRectGetMaxX(area) - tick, y - 0.5, tick, 1.0));
            if (t.major) {
                const CGFloat boxH = 12.0 * ts;
                CGRect box = CGRectMake(area.origin.x + (bothSides ? 3 : 4), y - boxH / 2, area.size.width - (bothSides ? 6 : 4), boxH);
                // Keep the end labels inside the scale.
                box.origin.y = std::max(area.origin.y - boxH / 2, std::min(CGRectGetMaxY(area) - boxH * 0.67, box.origin.y));
                if (place(box)) drawText(label, box, font, fg, bothSides ? Align::Centre : Align::Left);
            }
        } else {
            const CGFloat x = std::round(area.origin.x + t.pos * length);
            const CGFloat tick = t.major ? 3.0 : 2.0;
            CGContextFillRect(ctx, CGRectMake(x - 0.5, area.origin.y, 1.0, tick));
            CGContextFillRect(ctx, CGRectMake(x - 0.5, CGRectGetMaxY(area) - tick, 1.0, tick));
            if (t.major) {
                CGRect box = CGRectMake(x - 14 * ts, area.origin.y, 28 * ts, area.size.height);
                box.origin.x = std::max(area.origin.x - 4, std::min(CGRectGetMaxX(area) - 24 * ts, box.origin.x));
                if (place(box)) drawText(label, box, font, fg);
            }
        }
    }
}

// Correlation (-1..+1) or balance (L..R) strip.
void drawStereoRow(CGContextRef ctx, CGRect row, double value, bool silent, bool balance, const DisplaySettings &s) {
    const Palette &p = s.palette;
    const CGFloat t = s.textScale;
    NSFont *font = monoFont(8.5 * t);
    NSColor *dim = color(p.text, 0.62);
    const CGFloat labelW = 22.0 * t;
    CGRect left = CGRectMake(row.origin.x, row.origin.y, labelW, row.size.height);
    CGRect right = CGRectMake(CGRectGetMaxX(row) - labelW, row.origin.y, labelW, row.size.height);
    drawText(balance ? @"L" : @"-1", left, font, dim);
    drawText(balance ? @"R" : @"+1", right, font, dim);

    const CGFloat barH = 5.0;
    CGRect track = CGRectMake(row.origin.x + labelW, std::round(CGRectGetMidY(row) - barH / 2.0),
                              row.size.width - 2 * labelW, barH);
    fillRounded(ctx, track, 1.5, cg(p.text, p.dark ? 0.08 : 0.10));
    const CGFloat mid = std::round(CGRectGetMidX(track));
    const CGFloat half = track.size.width / 2.0;
    if (!silent) {
        // Balance: full deflection at 12 dB difference.
        const double v = balance ? std::max(-1.0, std::min(1.0, value / 12.0)) : value;
        const CGFloat x = mid + v * half;
        uint32_t c;
        if (balance) c = std::fabs(value) > 3.0 ? p.warn : p.safe;
        else c = value < 0 ? p.over : (value < 0.3 ? p.warn : p.safe);
        CGContextSetFillColorWithColor(ctx, cg(c, 0.9));
        CGContextFillRect(ctx, CGRectMake(std::min(mid, x), track.origin.y, std::fabs(x - mid), barH));
        CGContextSetFillColorWithColor(ctx, cg(c));
        CGContextFillRect(ctx, CGRectMake(std::max(track.origin.x, std::min(CGRectGetMaxX(track) - 2, x - 1)),
                                          track.origin.y - 2, 2, barH + 4));
    }
    CGContextSetFillColorWithColor(ctx, cg(p.text, 0.5));
    CGContextFillRect(ctx, CGRectMake(mid - 0.5, track.origin.y - 1, 1, barH + 2));
}

void drawStatCell(CGRect cell, NSString *label, NSString *value, NSString *unit, NSColor *valueColor,
                  const DisplaySettings &s) {
    const CGFloat t = s.textScale;
    NSFont *labelFont = [NSFont systemFontOfSize:8.5 * t weight:NSFontWeightSemibold];
    NSFont *valueFont = monoFont(11.0 * t, NSFontWeightSemibold);
    NSFont *unitFont = [NSFont systemFontOfSize:8.0 * t];
    const CGFloat labelW = 24.0 * t, unitW = 30.0 * t;
    drawText(label, CGRectMake(cell.origin.x, cell.origin.y, labelW, cell.size.height), labelFont,
             color(s.palette.text, 0.55), Align::Left);
    drawText(value, CGRectMake(cell.origin.x + labelW, cell.origin.y, cell.size.width - labelW - unitW, cell.size.height),
             valueFont, valueColor, Align::Right);
    drawText(unit, CGRectMake(CGRectGetMaxX(cell) - unitW + 3, cell.origin.y, unitW - 3, cell.size.height), unitFont,
             color(s.palette.text, 0.55), Align::Left);
}

} // namespace

#pragma mark - Entry points

void MeterRenderer::draw(CGContextRef ctx, CGRect bounds, const DisplaySettings &s, const Snapshot &snap) {
    _bounds = bounds;
    _analog = s.style == MeterStyle::Analog;
    if ((s.palette.background >> 24) != 0) {
        CGContextSetFillColorWithColor(ctx, cg(s.palette.background));
        CGContextFillRect(ctx, bounds);
    }
    if (_analog) drawAnalog(ctx, bounds, s, snap);
    else drawDigital(ctx, bounds, s, snap);
}

HitArea MeterRenderer::hitTest(CGPoint p) const {
    if (_analog) return CGRectContainsPoint(_bounds, p) ? HitArea::Peaks : HitArea::None;
    auto in = [&](const meter_layout::Rect &r) { return !r.empty() && CGRectContainsPoint(CGRectInset(toCG(r), -3, -3), p); };
    if (in(_layout.stats) || in(_layout.bar[BarM]) || in(_layout.bar[BarS]) ||
        in(_layout.readout[BarM]) || in(_layout.readout[BarS])) return HitArea::Loudness;
    if (in(_layout.bar[BarL]) || in(_layout.bar[BarR]) || in(_layout.readout[BarL]) ||
        in(_layout.readout[BarR]) || in(_layout.clip[0]) || in(_layout.clip[1]) || in(_layout.scale)) return HitArea::Peaks;
    return HitArea::None;
}

#pragma mark - Digital

void MeterRenderer::drawDigital(CGContextRef ctx, CGRect bounds, const DisplaySettings &s, const Snapshot &snap) {
    const Palette &p = s.palette;
    Input in;
    in.width = bounds.size.width;
    in.height = bounds.size.height;
    in.orientation = s.orientation;
    in.readouts = s.showReadouts;
    in.loudness = s.showLoudness;
    in.correlation = s.showCorrelation;
    in.balance = s.showBalance;
    in.text = s.textScale;
    _layout = layout(in);
    const Result &L = _layout;
    const bool vertical = L.vertical;

    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, bounds.origin.x, bounds.origin.y);

    const BarScale levelScale(s.floorDb, s.spacing, s.kReference());
    const BarScale loudScale(s.floorDb, s.spacing, 0.0);
    Zones levelZones { levelScale.position(s.warnStart()), levelScale.position(s.overStart()), p.safe, p.warn, p.over };
    // Loudness bars: their own colour up to the target, warning colour above.
    const double targetPos = loudScale.position(s.loudnessTarget);
    Zones loudZones { targetPos, 2.0, p.loudness, p.warn, p.over };

    // Level bars
    for (int c = 0; c < 2; ++c) {
        if (L.bar[c].empty()) continue;
        const ChannelReading &r = snap.ch[c];
        BarValues v;
        switch (s.barMode) {
            case BarMode::Peak: v = { r.peakDb, kFloorDb, r.holdDb }; break;
            case BarMode::Rms:  v = { r.rmsDb, kFloorDb, kFloorDb }; break;
            default:            v = { r.rmsDb, r.peakDb, r.holdDb }; break;
        }
        drawBar(ctx, toCG(L.bar[c]), vertical, levelScale, v, levelZones, s);
    }
    // Loudness bars
    for (int i = BarM; i <= BarS; ++i) {
        if (L.bar[i].empty()) continue;
        const double v = i == BarM ? snap.momentary : snap.shortTerm;
        drawBar(ctx, toCG(L.bar[i]), vertical, loudScale, { std::isfinite(v) ? v : kFloorDb, kFloorDb, kFloorDb },
                loudZones, s);
        // Target marker
        CGRect bar = toCG(L.bar[i]);
        if (vertical) bar = CGRectInset(bar, -2, 0);
        else bar = CGRectInset(bar, 0, -2);
        drawMarker(ctx, bar, vertical, targetPos, 1.0, cg(p.text, 0.8));
    }

    // Scales
    if (!L.scale.empty()) drawScaleTicks(ctx, toCG(L.scale), vertical, levelScale, s, true);
    if (!L.loudnessScale.empty()) drawScaleTicks(ctx, toCG(L.loudnessScale), vertical, loudScale, s, false);

    // Labels under (or beside) the bars, and the scale unit
    const CGFloat t = s.textScale;
    NSFont *labelFont = [NSFont systemFontOfSize:9 * t weight:NSFontWeightSemibold];
    NSColor *labelColor = color(p.text, 0.6);
    static NSString *const kNames[BarCount] = { @"L", @"R", @"M", @"S" };
    for (int i = 0; i < BarCount; ++i) {
        if (!L.label[i].empty() && !L.bar[i].empty()) drawText(kNames[i], toCG(L.label[i]), labelFont, labelColor);
    }
    if (vertical && !L.scale.empty()) {
        NSString *unit = s.scale == ScaleType::Dbfs ? @"dB" :
                         [NSString stringWithFormat:@"K-%d", (int)-s.kReference()];
        drawText(unit, CGRectMake(L.scale.x, L.label[BarL].y, L.scale.w, L.m.labelSize), monoFont(8 * t), color(p.text, 0.45));
        if (!L.loudnessScale.empty()) {
            drawText(@"LUFS", CGRectMake(L.loudnessScale.x, L.label[BarS].y, L.loudnessScale.w, L.m.labelSize),
                     monoFont(8 * t), color(p.text, 0.45));
        }
    }

    // Clip lights
    for (int c = 0; c < 2; ++c) {
        if (L.clip[c].empty() || L.bar[c].empty()) continue;
        fillRounded(ctx, toCG(L.clip[c]), 1.5, snap.ch[c].clip ? cg(p.over) : cg(p.text, p.dark ? 0.12 : 0.14));
    }

    // Readouts: session peak for L / R, current loudness for M / S
    NSFont *readoutFont = monoFont(10 * t, NSFontWeightSemibold);
    for (int i = 0; i < BarCount; ++i) {
        if (L.readout[i].empty() || L.bar[i].empty()) continue;
        CGRect box = toCG(L.readout[i]);
        if (i <= BarR) {
            const ChannelReading &r = snap.ch[i];
            if (r.clip) {
                fillRounded(ctx, CGRectInset(box, 1, 0), 2.5, cg(p.over));
                drawText(formatDb(r.maxDb), box, readoutFont, [NSColor whiteColor]);
            } else {
                drawText(formatDb(r.maxDb), box, readoutFont, color(p.text, 0.92));
            }
        } else {
            const double v = i == BarM ? snap.momentary : snap.shortTerm;
            const bool above = std::isfinite(v) && v > s.loudnessTarget;
            drawText(formatDb(v), box, readoutFont, above ? color(p.warn) : color(p.text, 0.92));
        }
    }

    // Loudness figures
    if (!L.stats.empty()) {
        CGRect st = toCG(L.stats);
        NSColor *fg = color(p.text, 0.95);
        const double plr = std::isfinite(snap.integrated) && snap.truePeakMaxDb > -99 ?
                           snap.truePeakMaxDb - snap.integrated : NAN;
        NSString *tpLabel = s.truePeak ? @"TP" : @"PK";
        NSString *tpUnit = s.truePeak ? @"dBTP" : @"dBFS";
        NSColor *tpColor = snap.truePeakMaxDb > -1.0 ? color(p.over) : fg;
        const CGFloat rowH = L.m.statsRow;
        if (L.statsTwoColumns) {
            const CGFloat colW = std::floor((st.size.width - 8.0) / 2.0);
            CGRect c00 = CGRectMake(st.origin.x, st.origin.y, colW, rowH);
            CGRect c01 = CGRectMake(st.origin.x + colW + 8.0, st.origin.y, colW, rowH);
            CGRect c10 = CGRectOffset(c00, 0, rowH + 1);
            CGRect c11 = CGRectOffset(c01, 0, rowH + 1);
            drawStatCell(c00, @"I", formatDb(snap.integrated), @"LUFS", fg, s);
            drawStatCell(c01, @"LRA", std::isfinite(snap.integrated) ? [NSString stringWithFormat:@"%.1f", snap.range] : @"–",
                         @"LU", fg, s);
            drawStatCell(c10, tpLabel, formatDb(snap.truePeakMaxDb), tpUnit, tpColor, s);
            drawStatCell(c11, @"PLR", std::isfinite(plr) ? [NSString stringWithFormat:@"%.1f", plr] : @"–", @"LU", fg, s);
        } else {
            drawStatCell(CGRectMake(st.origin.x, st.origin.y, st.size.width, rowH), @"I",
                         formatDb(snap.integrated), @"LUFS", fg, s);
            drawStatCell(CGRectMake(st.origin.x, st.origin.y + rowH + 1, st.size.width, rowH), tpLabel,
                         formatDb(snap.truePeakMaxDb), tpUnit, tpColor, s);
        }
    }

    // Stereo
    if (!L.correlation.empty()) {
        drawStereoRow(ctx, toCG(L.correlation), snap.correlation, snap.stereoSilent && snap.channels != 1, false, s);
    }
    if (!L.balance.empty()) {
        drawStereoRow(ctx, toCG(L.balance), snap.balanceDb, snap.stereoSilent, true, s);
    }

    CGContextRestoreGState(ctx);
}

#pragma mark - Analog

namespace {

struct FaceColors {
    uint32_t faceCentre, faceEdge;   // backlight gradient
    uint32_t ink;                    // scale, numbers
    uint32_t red;                    // +0..+3 zone
    uint32_t needle[2];              // per channel (second used on a shared face)
    uint32_t bezel;
    uint32_t pivot;
    CGFloat glass;                   // glare strength
};

FaceColors faceColors(const DisplaySettings &s) {
    const Palette &p = s.palette;
    switch (s.face) {
        case FaceStyle::Dark:
            return { 0xFF26282B, 0xFF121315, 0xFFE8E4DA, 0xFFFF5A3C, { 0xFFFFB347, 0xFF7FC8FF },
                     0xFF050505, 0xFF3A3C40, 0.07 };
        case FaceStyle::Theme: {
            // Face slightly off the panel background so it reads as a meter.
            const uint32_t bg = p.background | 0xFF000000u;
            auto mix = [](uint32_t a, uint32_t b, double t) {
                auto ch = [&](int sh) {
                    return (uint32_t)std::lround(((a >> sh) & 0xFF) * (1 - t) + ((b >> sh) & 0xFF) * t) << sh;
                };
                return 0xFF000000u | ch(16) | ch(8) | ch(0);
            };
            const uint32_t centre = mix(bg, p.text, p.dark ? 0.10 : 0.04);
            return { centre, bg, p.text, p.over, { p.safe, p.loudness },
                     mix(bg, 0xFF000000u, 0.5), mix(bg, p.text, 0.25), p.dark ? 0.05 : 0.10 };
        }
        case FaceStyle::Vintage:
        default:
            return { 0xFFFFF3CF, 0xFFE2C27A, 0xFF231F1A, 0xFFC4291C, { 0xFF161412, 0xFFB3241A },
                     0xFF1C1A17, 0xFF2A2724, 0.16 };
    }
}

CGPoint polar(CGPoint pivot, double radius, double degrees) {
    const double a = degrees * kPi / 180.0;
    // Angle from vertical, y grows downward.
    return CGPointMake(pivot.x + radius * std::sin(a), pivot.y - radius * std::cos(a));
}

void strokeArc(CGContextRef ctx, CGPoint pivot, double radius, double fromDeg, double toDeg, CGFloat width, CGColorRef c) {
    // CG angles: from +x axis, counter-clockwise in a y-up space; our CTM is
    // flipped, so build the arc from sampled points instead.
    const int steps = std::max(8, (int)std::fabs(toDeg - fromDeg));
    CGContextBeginPath(ctx);
    for (int i = 0; i <= steps; ++i) {
        const CGPoint pt = polar(pivot, radius, fromDeg + (toDeg - fromDeg) * i / steps);
        if (i == 0) CGContextMoveToPoint(ctx, pt.x, pt.y);
        else CGContextAddLineToPoint(ctx, pt.x, pt.y);
    }
    CGContextSetStrokeColorWithColor(ctx, c);
    CGContextSetLineWidth(ctx, width);
    CGContextStrokePath(ctx);
}

void drawFace(CGContextRef ctx, CGRect cell, const DisplaySettings &s, const Snapshot &snap,
              const int *channels, int needleCount, NSString *caption) {
    // A classic face is about 1.55 : 1.
    const CGFloat aspect = 1.55;
    CGFloat w = cell.size.width, h = w / aspect;
    if (h > cell.size.height) { h = cell.size.height; w = h * aspect; }
    if (w < 40 || h < 26) return;
    const CGRect face = CGRectMake(std::round(CGRectGetMidX(cell) - w / 2), std::round(CGRectGetMidY(cell) - h / 2),
                                   std::round(w), std::round(h));
    const FaceColors fc = faceColors(s);
    const CGFloat corner = std::max(3.0, w * 0.035);

    CGContextSaveGState(ctx);

    // Bezel and face
    CGPathRef outer = CGPathCreateWithRoundedRect(face, corner, corner, NULL);
    CGContextAddPath(ctx, outer);
    CGContextSetFillColorWithColor(ctx, cg(fc.bezel));
    CGContextFillPath(ctx);
    const CGFloat bezelW = std::max(1.5, w * 0.012);
    const CGRect inner = CGRectInset(face, bezelW, bezelW);
    CGPathRef innerPath = CGPathCreateWithRoundedRect(inner, corner * 0.8, corner * 0.8, NULL);
    CGContextAddPath(ctx, innerPath);
    CGContextClip(ctx);

    // Backlight: brightest low in the middle, falling off to the edges.
    {
        CGColorSpaceRef space = JLCreateThemeColorSpace();
        CGColorRef stops[2] = { cg(fc.faceCentre), cg(fc.faceEdge) };
        CFArrayRef arr = CFArrayCreate(NULL, (const void **)stops, 2, &kCFTypeArrayCallBacks);
        const CGFloat locs[2] = { 0.0, 1.0 };
        CGGradientRef g = CGGradientCreateWithColors(space, arr, locs);
        const CGPoint c = CGPointMake(CGRectGetMidX(inner), inner.origin.y + inner.size.height * 0.78);
        CGContextDrawRadialGradient(ctx, g, c, 0, c, inner.size.width * 0.72, kCGGradientDrawsAfterEndLocation);
        CGGradientRelease(g);
        CFRelease(arr);
        CGColorSpaceRelease(space);
    }

    const CGFloat H = inner.size.height, Wd = inner.size.width;
    // Radius chosen so the outer numbers at both ends stay on the face.
    const double R = std::min(0.80 * H, 0.52 * Wd);
    const CGPoint pivot = CGPointMake(CGRectGetMidX(inner), inner.origin.y + 0.30 * H + R);
    const double half = vu_face::kSweepDegrees / 2.0;
    const double zeroDeg = vu_face::angle(0.0);
    const CGFloat line = std::max(1.0, H * 0.008);

    // Scale arc, red zone above 0 VU
    strokeArc(ctx, pivot, R, -half, zeroDeg, line, cg(fc.ink));
    strokeArc(ctx, pivot, R + H * 0.022, zeroDeg, half, H * 0.04, cg(fc.red));
    strokeArc(ctx, pivot, R, zeroDeg, half, line, cg(fc.red));

    // Tick marks and numbers
    NSFont *numFont = [NSFont systemFontOfSize:std::max(7.0, H * 0.085) weight:NSFontWeightMedium];
    CGContextSetLineCap(ctx, kCGLineCapButt);
    for (double vu : vu_face::majorMarks()) {
        const double deg = vu_face::angle(vu);
        const uint32_t ink = vu > 0 ? fc.red : fc.ink;
        CGContextSetStrokeColorWithColor(ctx, cg(ink));
        CGContextSetLineWidth(ctx, line * 1.4);
        const CGPoint a = polar(pivot, R, deg), b = polar(pivot, R + H * 0.075, deg);
        CGContextMoveToPoint(ctx, a.x, a.y);
        CGContextAddLineToPoint(ctx, b.x, b.y);
        CGContextStrokePath(ctx);
        const CGPoint t = polar(pivot, R + H * 0.15, deg);
        NSString *label = [NSString stringWithFormat:@"%d", (int)std::fabs(vu)];
        drawText(label, CGRectMake(t.x - H * 0.12, t.y - H * 0.06, H * 0.24, H * 0.12), numFont, color(ink));
    }
    for (double vu : vu_face::minorMarks()) {
        const double deg = vu_face::angle(vu);
        CGContextSetStrokeColorWithColor(ctx, cg(vu > 0 ? fc.red : fc.ink));
        CGContextSetLineWidth(ctx, line);
        const CGPoint a = polar(pivot, R, deg), b = polar(pivot, R + H * 0.045, deg);
        CGContextMoveToPoint(ctx, a.x, a.y);
        CGContextAddLineToPoint(ctx, b.x, b.y);
        CGContextStrokePath(ctx);
    }
    // Signs just inside the ends of the scale
    NSFont *signFont = [NSFont systemFontOfSize:std::max(7.0, H * 0.09) weight:NSFontWeightMedium];
    {
        const CGPoint l = polar(pivot, R - H * 0.14, -half + 3.0);
        const CGPoint r = polar(pivot, R - H * 0.12, half - 3.0);
        drawText(@"−", CGRectMake(l.x - H * 0.08, l.y - H * 0.07, H * 0.16, H * 0.14), signFont, color(fc.ink));
        drawText(@"+", CGRectMake(r.x - H * 0.08, r.y - H * 0.07, H * 0.16, H * 0.14), signFont, color(fc.red));
    }

    // Percentage scale inside the arc (100% = 0 VU)
    NSFont *pctFont = [NSFont systemFontOfSize:std::max(6.0, H * 0.052)];
    NSColor *pctColor = color(fc.ink, 0.75);
    const double pctR = R - H * 0.03;
    strokeArc(ctx, pivot, pctR, vu_face::angle(-60.0), zeroDeg, line * 0.7, cg(fc.ink, 0.6));
    for (int pct = 0; pct <= 100; pct += 20) {
        const double deg = -half + vu_face::percentFraction(pct) * vu_face::kSweepDegrees;
        CGContextSetStrokeColorWithColor(ctx, cg(fc.ink, 0.75));
        CGContextSetLineWidth(ctx, line * 0.8);
        const CGPoint a = polar(pivot, pctR, deg), b = polar(pivot, pctR - H * 0.035, deg);
        CGContextMoveToPoint(ctx, a.x, a.y);
        CGContextAddLineToPoint(ctx, b.x, b.y);
        CGContextStrokePath(ctx);
        if (pct > 0) {
            const CGPoint t = polar(pivot, pctR - H * 0.085, deg);
            drawText([NSString stringWithFormat:@"%d", pct], CGRectMake(t.x - H * 0.09, t.y - H * 0.04, H * 0.18, H * 0.08),
                     pctFont, pctColor);
        }
    }

    // Legend
    NSString *legend = s.needle == NeedleBallistics::VU ? @"VU" : @"PPM";
    NSFont *legendFont = [NSFont systemFontOfSize:std::max(9.0, H * 0.17) weight:NSFontWeightRegular];
    drawText(legend, CGRectMake(inner.origin.x, inner.origin.y + H * 0.56, Wd, H * 0.2), legendFont, color(fc.ink, 0.9));
    if (caption.length) {
        // On a shared face each channel letter takes its needle's colour.
        NSFont *capFont = [NSFont systemFontOfSize:std::max(7.0, H * 0.075) weight:NSFontWeightSemibold];
        const CGRect capBox = CGRectMake(inner.origin.x + Wd * 0.05, inner.origin.y + H * 0.80, Wd * 0.25, H * 0.12);
        if (needleCount > 1) {
            NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
            static NSString *const kLetters[2] = { @"L", @"R" };
            for (int i = 0; i < needleCount; ++i) {
                [text appendAttributedString:[[NSAttributedString alloc]
                    initWithString:[NSString stringWithFormat:@"%@%@", i ? @"  " : @"", kLetters[channels[i]]]
                        attributes:@{ NSFontAttributeName: capFont, NSForegroundColorAttributeName: color(fc.needle[i]) }]];
            }
            const NSSize sz = text.size;
            [text drawAtPoint:NSMakePoint(capBox.origin.x, capBox.origin.y + (capBox.size.height - sz.height) / 2)];
        } else {
            drawText(caption, capBox, capFont, color(fc.ink, 0.7), Align::Left);
        }
    }
    NSString *refText = [NSString stringWithFormat:@"0 = %.0f dBFS", s.referenceDbfs];
    NSFont *refFont = [NSFont systemFontOfSize:std::max(6.0, H * 0.05)];
    drawText(refText, CGRectMake(inner.origin.x + Wd * 0.62, inner.origin.y + H * 0.82, Wd * 0.34, H * 0.1),
             refFont, color(fc.ink, 0.55), Align::Right);

    // Peak LED (any of this face's channels over the threshold)
    if (s.peakLed) {
        bool lit = false;
        for (int i = 0; i < needleCount; ++i) lit = lit || snap.ch[channels[i]].peakDb > s.peakLedDbfs;
        const CGFloat r = std::max(2.5, H * 0.035);
        const CGPoint c = CGPointMake(CGRectGetMaxX(inner) - Wd * 0.08, inner.origin.y + H * 0.13);
        if (lit) {
            CGContextSaveGState(ctx);
            CGContextSetShadowWithColor(ctx, CGSizeZero, r * 3.0, cg(0xFFFF3B20));
            fillRounded(ctx, CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), r, cg(0xFFFF4A2E));
            CGContextRestoreGState(ctx);
        } else {
            fillRounded(ctx, CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), r, cg(0xFF5A1C14));
        }
        NSFont *ledFont = [NSFont systemFontOfSize:std::max(5.0, H * 0.042) weight:NSFontWeightSemibold];
        drawText(@"PEAK", CGRectMake(c.x - H * 0.1, c.y + r + 1, H * 0.2, H * 0.06), ledFont, color(fc.ink, 0.6));
    }

    // Needles, drawn last needle first so channel 0 sits on top
    const CGFloat needleW = std::max(1.0, H * 0.011);
    for (int i = needleCount - 1; i >= 0; --i) {
        const double deg = vu_face::angle(snap.ch[channels[i]].needleDb);
        const CGPoint tip = polar(pivot, R + H * 0.10, deg);
        const CGPoint base = polar(pivot, R * 0.32, deg);
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(H * 0.012, H * 0.018), H * 0.012, cg(0xFF000000, 0.35));
        CGContextSetStrokeColorWithColor(ctx, cg(fc.needle[needleCount > 1 ? i : 0]));
        CGContextSetLineWidth(ctx, needleW);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextMoveToPoint(ctx, base.x, base.y);
        CGContextAddLineToPoint(ctx, tip.x, tip.y);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }

    // Pivot housing across the bottom edge
    {
        const CGFloat pr = H * 0.20;
        const CGPoint c = CGPointMake(CGRectGetMidX(inner), CGRectGetMaxY(inner) + pr * 0.35);
        CGContextSetFillColorWithColor(ctx, cg(fc.pivot));
        CGContextFillEllipseInRect(ctx, CGRectMake(c.x - pr * 1.25, c.y - pr, pr * 2.5, pr * 2));
    }

    // Glass glare over the upper half
    if (fc.glass > 0) {
        CGColorSpaceRef space = JLCreateThemeColorSpace();
        CGColorRef stops[2] = { cg(0xFFFFFFFF, fc.glass), cg(0xFFFFFFFF, 0.0) };
        CFArrayRef arr = CFArrayCreate(NULL, (const void **)stops, 2, &kCFTypeArrayCallBacks);
        const CGFloat locs[2] = { 0.0, 1.0 };
        CGGradientRef g = CGGradientCreateWithColors(space, arr, locs);
        CGContextDrawLinearGradient(ctx, g, inner.origin, CGPointMake(inner.origin.x, inner.origin.y + H * 0.5), 0);
        CGGradientRelease(g);
        CFRelease(arr);
        CGColorSpaceRelease(space);
    }

    CGPathRelease(innerPath);
    CGPathRelease(outer);
    CGContextRestoreGState(ctx);

    // Inner shadow along the top edge of the window
    CGContextSaveGState(ctx);
    CGPathRef edge = CGPathCreateWithRoundedRect(inner, corner * 0.8, corner * 0.8, NULL);
    CGContextAddPath(ctx, edge);
    CGContextClip(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, H * 0.02), H * 0.04, cg(0xFF000000, 0.45));
    CGContextSetStrokeColorWithColor(ctx, cg(0xFF000000));
    CGContextSetLineWidth(ctx, H * 0.04);
    CGPathRef ring = CGPathCreateWithRoundedRect(CGRectInset(inner, -H * 0.02, -H * 0.02), corner, corner, NULL);
    CGContextAddPath(ctx, ring);
    CGContextStrokePath(ctx);
    CGPathRelease(ring);
    CGPathRelease(edge);
    CGContextRestoreGState(ctx);
}

} // namespace

void MeterRenderer::drawAnalog(CGContextRef ctx, CGRect bounds, const DisplaySettings &s, const Snapshot &snap) {
    const CGRect area = CGRectInset(bounds, 4, 4);
    const bool mono = snap.channels == 1;
    NeedleLayout layout = s.needleLayout;
    if (mono) layout = NeedleLayout::Single;

    if (layout == NeedleLayout::Single) {
        static const int both[2] = { 0, 1 };
        static const int left[1] = { 0 };
        drawFace(ctx, area, s, snap, mono ? left : both, mono ? 1 : 2, mono ? @"MONO" : @"LR");
        return;
    }
    // Two faces: side by side or stacked, whichever gives the bigger face.
    const CGFloat aspect = 1.55;
    auto faceArea = [&](CGFloat cw, CGFloat ch) {
        CGFloat w = cw, h = w / aspect;
        if (h > ch) { h = ch; w = h * aspect; }
        return w * h;
    };
    const CGFloat gap = 6.0;
    const bool sideBySide = faceArea((area.size.width - gap) / 2, area.size.height) >=
                            faceArea(area.size.width, (area.size.height - gap) / 2);
    CGRect a, b;
    if (sideBySide) {
        const CGFloat cw = (area.size.width - gap) / 2;
        a = CGRectMake(area.origin.x, area.origin.y, cw, area.size.height);
        b = CGRectMake(area.origin.x + cw + gap, area.origin.y, cw, area.size.height);
    } else {
        const CGFloat ch = (area.size.height - gap) / 2;
        a = CGRectMake(area.origin.x, area.origin.y, area.size.width, ch);
        b = CGRectMake(area.origin.x, area.origin.y + ch + gap, area.size.width, ch);
    }
    static const int l[1] = { 0 }, r[1] = { 1 };
    drawFace(ctx, a, s, snap, l, 1, @"L");
    drawFace(ctx, b, s, snap, r, 1, @"R");
}

} // namespace meter
