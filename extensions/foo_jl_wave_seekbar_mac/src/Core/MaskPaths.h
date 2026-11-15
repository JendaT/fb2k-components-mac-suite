//
//  MaskPaths.h
//  foo_wave_seekbar_mac
//
//  The filled shapes of the waveform's greyscale masks, one vertex per pixel
//  column centre, added to a CGContext's path a run of columns at a time.
//  Header-only, tested standalone against the exact pixel coverage.
//

#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <algorithm>
#include <cstddef>
#include <vector>

namespace waveseek::masks {

// Masks are filled kFillChunk pixel columns at a time: one path with a
// vertex per column across a Retina seekbar takes CoreGraphics 10-70 ms to
// fill, which made zooming and resizing stutter, and it antialiases such a
// path less exactly (up to 34/255 off the true coverage; runs stay within
// 2/255). Runs end on whole pixels, so they meet without seams; whatever
// shares a pixel (a lane's two halves at its centre line) goes in one run.
constexpr size_t kFillChunk = 32;

// Calls addRun(c0, c1) for each run of columns and fills what it added
template <typename AddRun>
void fillInRuns(CGContextRef ctx, size_t columns, AddRun addRun) {
    for (size_t c0 = 0; c0 < columns; c0 += kFillChunk) {
        addRun(c0, std::min(columns, c0 + kFillChunk));
        CGContextFillPath(ctx);
    }
}

// An outline's height at the whole pixel x: halfway between the column
// centres either side, level with the first and last centres at the ends
inline float heightAt(const std::vector<float>& v, size_t x) {
    const size_t n = v.size();
    if (n == 0) return 0.0f;
    return x == 0 ? v[0] : x >= n ? v[n - 1] : (v[x - 1] + v[x]) * 0.5f;
}

// Columns [c0, c1) of the area between two signed outlines around a lane
// centre (Simple)
inline void addBand(CGContextRef ctx, const std::vector<float>& top, const std::vector<float>& bottom,
                    size_t c0, size_t c1, CGFloat centerY, CGFloat amplitude) {
    if (c0 >= c1 || c1 > top.size() || c1 > bottom.size()) return;
    CGContextMoveToPoint(ctx, c0, centerY + heightAt(top, c0) * amplitude);
    for (size_t c = c0; c < c1; ++c) CGContextAddLineToPoint(ctx, c + 0.5, centerY + top[c] * amplitude);
    CGContextAddLineToPoint(ctx, c1, centerY + heightAt(top, c1) * amplitude);
    CGContextAddLineToPoint(ctx, c1, centerY + heightAt(bottom, c1) * amplitude);
    for (size_t c = c1; c-- > c0;) CGContextAddLineToPoint(ctx, c + 0.5, centerY + bottom[c] * amplitude);
    CGContextAddLineToPoint(ctx, c0, centerY + heightAt(bottom, c0) * amplitude);
    CGContextClosePath(ctx);
}

// Columns [c0, c1) of the area between the centre line and the heights
// (Layered); `dir` +1 grows up, -1 down
inline void addHalfShape(CGContextRef ctx, const std::vector<float>& frac, size_t c0, size_t c1,
                         CGFloat centerY, CGFloat amplitude, CGFloat dir) {
    if (c0 >= c1 || c1 > frac.size()) return;
    CGContextMoveToPoint(ctx, c0, centerY);
    CGContextAddLineToPoint(ctx, c0, centerY + dir * heightAt(frac, c0) * amplitude);
    for (size_t c = c0; c < c1; ++c) {
        CGContextAddLineToPoint(ctx, c + 0.5, centerY + dir * frac[c] * amplitude);
    }
    CGContextAddLineToPoint(ctx, c1, centerY + dir * heightAt(frac, c1) * amplitude);
    CGContextAddLineToPoint(ctx, c1, centerY);
    CGContextClosePath(ctx);
}

} // namespace waveseek::masks
