//
//  PhosphorBuffer.h
//  foo_jl_vectorscope_mac
//
//  Square intensity buffer that imitates an oscilloscope tube: every frame
//  the old image fades a little and the new trace is added on top, so the
//  beam leaves an afterglow. Pure C++ (no SDK, no Cocoa); the view turns the
//  rendered pixels into an image.
//

#pragma once

#include <cstddef>
#include <cstdint>
#include <vector>

class PhosphorBuffer {
public:
    // Reallocate as side x side and clear. No-op when the size is unchanged.
    void resize(int side);
    int  side() const { return _side; }
    void clear();

    // Fade the whole image by `keep` (0..1). Returns the brightest remaining
    // pixel, 0 once the image has fully died away.
    float decay(float keep);

    // Add a trace of `points` goniometer points (interleaved x/y, -1..1,
    // y up). Each point deposits `energy`. With `connect` the energy is
    // spread along the line from the previous point, so fast beam movement
    // draws dimmer, as on a real tube; otherwise each point is a single dot.
    // The stroke continues across calls until breakTrace().
    void addTrace(const float* xy, size_t points, float energy, bool connect);
    void breakTrace() { _havePrev = false; }

    // Tone-map into side * side RGBA pixels (4 bytes each, row 0 at the top)
    // through a 256-entry colour table from buildPhosphorLUT().
    void render(uint8_t* rgba, const uint32_t* lut) const;

    const std::vector<float>& pixels() const { return _pixels; }

private:
    inline void splat(float px, float py, float energy);

    int _side = 0;
    std::vector<float> _pixels;
    bool  _havePrev = false;
    float _prevX = 0.0f, _prevY = 0.0f;   // pixel coordinates
};

// Fill a 256-entry table mapping displayed intensity to a premultiplied
// RGBA pixel (bytes in memory order R, G, B, A) of the given 0xAARRGGBB
// trace colour. Intensity drives alpha, so the trace composites over any
// background. With `hotCore` the brightest values bleach towards white.
void buildPhosphorLUT(uint32_t argb, bool hotCore, uint32_t* lut);
