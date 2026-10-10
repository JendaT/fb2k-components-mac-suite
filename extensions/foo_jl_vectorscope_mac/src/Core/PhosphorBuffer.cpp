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
    float peak = 0.0f;
    float* p = _pixels.data();
    const size_t n = _pixels.size();
    for (size_t i = 0; i < n; ++i) {
        float v = p[i] * keep;
        v = v < kFloor ? 0.0f : v;
        p[i] = v;
        peak = v > peak ? v : peak;
    }
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

        if (!connect || !_havePrev) {
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
        // Soft shoulder: intensity is unbounded, the display saturates gently.
        float v = p[i] / (1.0f + p[i]);
        if (!(v < 1.0f)) v = 1.0f;   // overflowed pixel
        const uint32_t px = lut[(int)(v * 255.0f + 0.5f)];
        std::memcpy(rgba + i * 4, &px, 4);
    }
}

void buildPhosphorLUT(uint32_t argb, bool hotCore, uint32_t* lut) {
    const float baseA = (float)((argb >> 24) & 0xFF) / 255.0f;
    const float base[3] = {
        (float)((argb >> 16) & 0xFF) / 255.0f,
        (float)((argb >> 8) & 0xFF) / 255.0f,
        (float)(argb & 0xFF) / 255.0f,
    };
    for (int i = 0; i < 256; ++i) {
        const float t = (float)i / 255.0f;
        // Only the top of the range bleaches, so the trace keeps its colour.
        float hot = 0.0f;
        if (hotCore && t > 0.6f) {
            const float h = (t - 0.6f) / 0.4f;
            hot = 0.75f * h * h;
        }
        const float alpha = t * baseA;
        uint8_t bytes[4];
        for (int c = 0; c < 3; ++c) {
            const float colour = base[c] + (1.0f - base[c]) * hot;
            bytes[c] = (uint8_t)(colour * alpha * 255.0f + 0.5f);
        }
        bytes[3] = (uint8_t)(alpha * 255.0f + 0.5f);
        std::memcpy(&lut[i], bytes, 4);
    }
}
