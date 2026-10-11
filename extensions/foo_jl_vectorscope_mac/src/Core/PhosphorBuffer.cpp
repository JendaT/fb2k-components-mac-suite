//
//  PhosphorBuffer.cpp
//  foo_jl_vectorscope_mac
//

#include "PhosphorBuffer.h"
#include <algorithm>
#include <cmath>
#include <cstring>

namespace {
    // Below this a pixel maps to table entry 0 anyway; snapping it to zero
    // lets the image reach a true "empty" state and keeps floats out of
    // denormal range.
    const float kFloor = 1e-3f;
    const float kMaxDotSize = 64.0f;

    // Soft shoulder: intensity is unbounded, the display saturates gently.
    inline int toneIndex(float intensity) {
        float v = intensity / (1.0f + intensity);
        if (!(v < 1.0f)) v = 1.0f;   // overflowed pixel
        return (int)(v * 255.0f + 0.5f);
    }

    // How far a displayed intensity bleaches towards white. Only the top of
    // the range does, so the trace keeps its colour.
    inline float hotCoreAmount(float t) {
        if (t <= 0.6f) return 0.0f;
        const float h = (t - 0.6f) / 0.4f;
        return 0.75f * h * h;
    }

    // Premultiplied pixel, bytes in memory order R, G, B, A.
    inline void writePixel(const float colour[3], float hot, float alpha, uint8_t* out) {
        for (int c = 0; c < 3; ++c) {
            const float bleached = colour[c] + (1.0f - colour[c]) * hot;
            out[c] = (uint8_t)(bleached * alpha * 255.0f + 0.5f);
        }
        out[3] = (uint8_t)(alpha * 255.0f + 0.5f);
    }

    inline void unpackColour(uint32_t argb, float rgb[3], float& alpha) {
        alpha  = (float)((argb >> 24) & 0xFF) / 255.0f;
        rgb[0] = (float)((argb >> 16) & 0xFF) / 255.0f;
        rgb[1] = (float)((argb >> 8) & 0xFF) / 255.0f;
        rgb[2] = (float)(argb & 0xFF) / 255.0f;
    }
}

void PhosphorBuffer::resize(int side) {
    if (side < 2) side = 2;
    if (side == _side) return;
    _side = side;
    _pixels.assign((size_t)side * (size_t)side, 0.0f);
    _havePrev = false;
}

void PhosphorBuffer::clear() {
    std::fill(_pixels.begin(), _pixels.end(), 0.0f);
    _havePrev = false;
}

float PhosphorBuffer::decay(float keep) {
    if (!(keep > 0.0f)) {   // also catches NaN
        std::fill(_pixels.begin(), _pixels.end(), 0.0f);
        return 0.0f;
    }
    if (keep > 1.0f) keep = 1.0f;
    float* p = _pixels.data();
    const size_t n = _pixels.size();
    // Independent peak lanes: a single running maximum would chain every
    // pixel to the one before and keep the loop from vectorising.
    enum { kLanes = 16 };
    float lanes[kLanes] = { 0.0f };
    size_t i = 0;
    for (; i + kLanes <= n; i += kLanes) {
        for (int j = 0; j < kLanes; ++j) {
            float v = p[i + j] * keep;
            v = v < kFloor ? 0.0f : v;
            p[i + j] = v;
            lanes[j] = v > lanes[j] ? v : lanes[j];
        }
    }
    float peak = 0.0f;
    for (; i < n; ++i) {
        float v = p[i] * keep;
        v = v < kFloor ? 0.0f : v;
        p[i] = v;
        peak = v > peak ? v : peak;
    }
    for (float lane : lanes) peak = lane > peak ? lane : peak;
    return peak;
}

// Bilinear deposit at a fractional pixel position. Positions outside the
// buffer (overshoot from gain) and non-finite ones are dropped.
inline void PhosphorBuffer::splat(float px, float py, float energy) {
    const float limit = (float)(_side - 1);
    if (!(px >= 0.0f && px < limit && py >= 0.0f && py < limit)) return;
    const int ix = (int)px;
    const int iy = (int)py;
    const float fx = px - (float)ix;
    const float fy = py - (float)iy;
    float* row0 = _pixels.data() + (size_t)iy * (size_t)_side + (size_t)ix;
    float* row1 = row0 + _side;
    row0[0] += energy * (1.0f - fx) * (1.0f - fy);
    row0[1] += energy * fx * (1.0f - fy);
    row1[0] += energy * (1.0f - fx) * fy;
    row1[1] += energy * fx * fy;
}

void PhosphorBuffer::setDotSize(float pixels) {
    if (!(pixels > 1.0f)) pixels = 1.0f;   // also catches NaN
    if (pixels > kMaxDotSize) pixels = kMaxDotSize;
    if (pixels == _dotSize) return;
    _dotSize = pixels;
    _dotSpan = 0;
    _dot.clear();
    if (pixels <= 1.0f) return;

    // Disc with a one-pixel soft edge, centred on the middle pixel.
    const float radius = pixels / 2.0f;
    const int reach = (int)std::ceil(radius);
    const int span = 2 * reach + 1;
    _dot.resize((size_t)span * (size_t)span);
    float sum = 0.0f;
    for (int y = 0; y < span; ++y) {
        for (int x = 0; x < span; ++x) {
            const float dx = (float)(x - reach), dy = (float)(y - reach);
            const float w = std::min(1.0f, std::max(0.0f, radius + 0.5f - std::sqrt(dx * dx + dy * dy)));
            _dot[(size_t)y * span + x] = w;
            sum += w;
        }
    }
    // Light grows with the diameter, not the area: a big dot stays visible
    // on its own without a dense cloud of them burning out.
    const float scale = pixels / sum;
    for (float& w : _dot) w *= scale;
    _dotSpan = span;
}

// Deposit the dot disc centred on the nearest pixel, clipped to the buffer.
// The centre obeys the same bounds as splat().
inline void PhosphorBuffer::stamp(float px, float py, float energy) {
    const float limit = (float)(_side - 1);
    if (!(px >= 0.0f && px < limit && py >= 0.0f && py < limit)) return;
    const int reach = _dotSpan / 2;
    const int cx = (int)(px + 0.5f);
    const int cy = (int)(py + 0.5f);
    const int x0 = std::max(cx - reach, 0), x1 = std::min(cx + reach, _side - 1);
    const int y0 = std::max(cy - reach, 0), y1 = std::min(cy + reach, _side - 1);
    for (int y = y0; y <= y1; ++y) {
        const float* w = _dot.data() + (size_t)(y - cy + reach) * (size_t)_dotSpan + (size_t)(x0 - cx + reach);
        float* row = _pixels.data() + (size_t)y * (size_t)_side + (size_t)x0;
        for (int x = 0; x <= x1 - x0; ++x) row[x] += energy * w[x];
    }
}

void PhosphorBuffer::addTrace(const float* xy, size_t points, float energy, bool connect) {
    if (_side < 2 || !(energy > 0.0f)) return;
    const float half = 0.5f * (float)(_side - 1);
    // A segment never needs more steps than this, however far the beam jumps.
    const int maxSteps = 2 * _side;

    for (size_t i = 0; i < points; ++i) {
        const float x = xy[2 * i];
        const float y = xy[2 * i + 1];
        if (!std::isfinite(x) || !std::isfinite(y)) {
            _havePrev = false;
            continue;
        }
        const float px = (x + 1.0f) * half;
        const float py = (1.0f - y) * half;   // row 0 is the top

        if (!connect) {
            if (_dotSpan > 0) stamp(px, py, energy);
            else splat(px, py, energy);
        } else if (!_havePrev) {
            splat(px, py, energy);
        } else {
            const float dx = px - _prevX;
            const float dy = py - _prevY;
            const float len = std::sqrt(dx * dx + dy * dy);
            int steps = len < (float)maxSteps ? (int)std::ceil(len) : maxSteps;
            if (steps < 1) steps = 1;
            const float e = energy / (float)steps;
            const float inv = 1.0f / (float)steps;
            // Start at 1: the previous call already drew the segment's origin.
            for (int k = 1; k <= steps; ++k) {
                const float t = (float)k * inv;
                splat(_prevX + dx * t, _prevY + dy * t, e);
            }
        }
        _prevX = px;
        _prevY = py;
        _havePrev = true;
    }
}

void PhosphorBuffer::render(uint8_t* rgba, const uint32_t* lut) const {
    const float* p = _pixels.data();
    const size_t n = _pixels.size();
    for (size_t i = 0; i < n; ++i) {
        const uint32_t px = lut[toneIndex(p[i])];
        std::memcpy(rgba + i * 4, &px, 4);
    }
}

void buildPhosphorLUT(uint32_t argb, bool hotCore, uint32_t* lut) {
    float base[3], baseA;
    unpackColour(argb, base, baseA);
    for (int i = 0; i < 256; ++i) {
        const float t = (float)i / 255.0f;
        uint8_t bytes[4];
        writePixel(base, hotCore ? hotCoreAmount(t) : 0.0f, t * baseA, bytes);
        std::memcpy(&lut[i], bytes, 4);
    }
}

void renderPhosphorBands(const PhosphorBuffer bands[kPhosphorBands], const uint32_t argb[kPhosphorBands],
                         bool hotCore, uint8_t* rgba) {
    const float* p[kPhosphorBands];
    float base[kPhosphorBands][3], baseA[kPhosphorBands];
    size_t n = bands[0].pixels().size();
    for (int b = 0; b < kPhosphorBands; ++b) {
        p[b] = bands[b].pixels().data();
        n = std::min(n, bands[b].pixels().size());
        unpackColour(argb[b], base[b], baseA[b]);
    }

    for (size_t i = 0; i < n; ++i) {
        uint8_t* out = rgba + i * 4;
        // Most of the image is dark most of the time.
        if (p[0][i] + p[1][i] + p[2][i] == 0.0f) {
            std::memset(out, 0, 4);
            continue;
        }
        float sum = 0.0f;       // of the bands' displayed intensities
        float dark = 1.0f;      // what all bands together leave unlit
        float weight = 0.0f;    // intensities scaled by each colour's alpha
        float colour[3] = { 0.0f, 0.0f, 0.0f };
        for (int b = 0; b < kPhosphorBands; ++b) {
            const int index = toneIndex(p[b][i]);
            if (index == 0) continue;
            const float t = (float)index / 255.0f;
            const float w = t * baseA[b];
            sum += t;
            dark *= 1.0f - t;
            weight += w;
            for (int c = 0; c < 3; ++c) colour[c] += base[b][c] * w;
        }
        if (!(weight > 0.0f)) {
            std::memset(out, 0, 4);
            continue;
        }
        const float t = 1.0f - dark;
        for (int c = 0; c < 3; ++c) colour[c] /= weight;
        writePixel(colour, hotCore ? hotCoreAmount(t) : 0.0f, t * weight / sum, out);
    }
}
