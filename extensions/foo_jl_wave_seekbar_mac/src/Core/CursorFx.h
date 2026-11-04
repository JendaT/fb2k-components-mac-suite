//
//  CursorFx.h
//  foo_wave_seekbar_mac
//
//  The maths behind the cursor effects that are more than a gradient:
//  hashing and noise, Glow's falloff, the level envelope Particles burst
//  from, the sparks themselves (a pure function of the playback time),
//  Firewall's heat field and its row of fires, Earthcrusher's colours,
//  crack tile and jagged line. No drawing: CursorEffectPainter turns these
//  into CoreGraphics. Header-only (with ThemeTokens.cpp), tested standalone.
//

#pragma once

#include "ThemeTokens.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace waveseek::fx {

// ---- Hashing and noise: effects as functions of time and place, not state

// Integer hash (lowbias32): well mixed and cheap
inline uint32_t hash(uint32_t x) {
    x ^= x >> 16;
    x *= 0x7FEB352Du;
    x ^= x >> 15;
    x *= 0x846CA68Bu;
    x ^= x >> 16;
    return x;
}
inline uint32_t hash(uint32_t a, uint32_t b) { return hash(a ^ hash(b + 0x9E3779B9u)); }
inline uint32_t hash(uint32_t a, uint32_t b, uint32_t c) { return hash(hash(a, b), c); }

// A hash as a float in [0, 1)
inline float unit(uint32_t h) { return (float)(h >> 8) * (1.0f / 16777216.0f); }

inline float smoothstep(float edge0, float edge1, float x) {
    const float t = std::clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

// Smooth value noise, -1..1, a lattice point at every whole x
inline float noise1(float x, uint32_t seed) {
    const float f = std::floor(x);
    const uint32_t i = (uint32_t)(int32_t)f;
    const float t = x - f;
    const float s = t * t * (3.0f - 2.0f * t);
    const float a = unit(hash(i, seed)) * 2.0f - 1.0f;
    const float b = unit(hash(i + 1, seed)) * 2.0f - 1.0f;
    return a + (b - a) * s;
}

// Value noise on a lattice that repeats every `period` units in x and y,
// -1..1, so a tile built from it repeats without a seam
inline float noise2(float x, float y, int period, uint32_t seed) {
    period = std::max(1, period);
    const float fx = std::floor(x), fy = std::floor(y);
    const int ix = (int)fx, iy = (int)fy;
    const float tx = x - fx, ty = y - fy;
    const float sx = tx * tx * (3.0f - 2.0f * tx), sy = ty * ty * (3.0f - 2.0f * ty);
    auto at = [&](int i, int j) {
        const uint32_t wi = (uint32_t)(((i % period) + period) % period);
        const uint32_t wj = (uint32_t)(((j % period) + period) % period);
        return unit(hash(wi, wj, seed)) * 2.0f - 1.0f;
    };
    const float bottom = at(ix, iy) + (at(ix + 1, iy) - at(ix, iy)) * sx;
    const float top = at(ix, iy + 1) + (at(ix + 1, iy + 1) - at(ix, iy + 1)) * sx;
    return bottom + (top - bottom) * sy;
}

// ---- Glow: light from a line falls off as 1 / (1 + (d / r)^2). Shifted and
// rescaled to reach 0 exactly at the reach, so the bloom has no edge.

inline float glowFalloff(float distance, float radius, float reach) {
    distance = std::fabs(distance);
    if (!(radius > 0.0f) || !(reach > 0.0f) || !(distance < reach)) return 0.0f;
    auto f = [&](float d) { const float q = d / radius; return 1.0f / (1.0f + q * q); };
    const float floor = f(reach);
    return std::max(0.0f, (f(distance) - floor) / (1.0f - floor));
}

struct GlowStop {
    float location;     // 0 at the cursor, 1 at the reach
    float alpha;        // 1 at the cursor, 0 at the reach
};
constexpr int kGlowStops = 9;

// Gradient stops for a reach of `reachRadii` radii, closer together near
// the cursor where the light changes fastest
inline std::array<GlowStop, kGlowStops> glowStops(float reachRadii) {
    std::array<GlowStop, kGlowStops> stops{};
    for (int i = 0; i < kGlowStops; ++i) {
        const float t = (float)i / (kGlowStops - 1);
        const float location = t * t;
        stops[i] = { location, glowFalloff(location * reachRadii, 1.0f, reachRadii) };
    }
    return stops;
}

// ---- How loud the track is around a moment, from its fine blocks' RMS.
// 1 is a loud passage of this track (the 95th percentile of its non-silent
// blocks), so a quiet recording bursts as much as a loud master. Onset is
// the rise over the moment before: kicks and snares, which is what makes
// the bursts land on the beat without knowing the tempo.

class LevelEnvelope {
public:
    static constexpr double kOnsetSeconds = 0.15;   // the window an onset rises over
    static constexpr double kSmoothSeconds = 0.3;   // smooth(): the trailing average
    static constexpr float kSilent = 1e-4f;         // RMS below -80 dBFS
    static constexpr float kMaxBurst = 1.5f;

    // RMS per block of one or two channels (rmsR null for one), each block
    // blockSeconds long
    void build(const float* rmsL, const float* rmsR, size_t count, double blockSeconds) {
        clear();
        if (!rmsL || count == 0 || !(blockSeconds > 0.0)) return;
        std::vector<float> level(count), loud;
        loud.reserve(count);
        for (size_t i = 0; i < count; ++i) {
            const float l = std::max(0.0f, rmsL[i]);
            const float r = rmsR ? std::max(0.0f, rmsR[i]) : l;
            const float rms = std::sqrt(0.5f * (l * l + r * r));
            level[i] = std::isfinite(rms) ? rms : 0.0f;
            if (level[i] > kSilent) loud.push_back(level[i]);
        }
        if (loud.empty()) return;   // silence: no bursts
        const size_t k = std::min(loud.size() - 1, loud.size() * 95 / 100);
        std::nth_element(loud.begin(), loud.begin() + (long)k, loud.end());
        const float reference = loud[k];
        for (float& v : level) v /= reference;

        // Onset: the level less the mean of the window before it; trailing
        // average for smooth(). Before the start counts as silence.
        const size_t ow = std::max<size_t>(1, (size_t)std::lround(kOnsetSeconds / blockSeconds));
        const size_t sw = std::max<size_t>(1, (size_t)std::lround(kSmoothSeconds / blockSeconds));
        onset_.assign(count, 0.0f);
        smooth_.assign(count, 0.0f);
        double before = 0.0, trailing = 0.0;
        for (size_t i = 0; i < count; ++i) {
            onset_[i] = std::max(0.0f, level[i] - (float)(before / ow));
            before += level[i];
            if (i >= ow) before -= level[i - ow];
            trailing += level[i];
            if (i >= sw) trailing -= level[i - sw];
            smooth_[i] = (float)(trailing / sw);
        }
        level_ = std::move(level);
        blockSeconds_ = blockSeconds;
    }

    void clear() {
        level_.clear();
        onset_.clear();
        smooth_.clear();
        blockSeconds_ = 0.0;
    }

    bool empty() const { return level_.empty(); }
    float level(double seconds) const { return sample(level_, seconds); }
    float onset(double seconds) const { return sample(onset_, seconds); }
    float smooth(double seconds) const { return sample(smooth_, seconds); }

    // Burst strength, 0..kMaxBurst: mostly the beats, some for sheer loudness
    float burst(double seconds) const {
        const float l = level(seconds);
        return std::min(kMaxBurst, 0.5f * l * l * l + 3.0f * onset(seconds));
    }

private:
    // Linear between block centres; nothing outside the track
    float sample(const std::vector<float>& v, double seconds) const {
        if (v.empty() || !(blockSeconds_ > 0.0) || !std::isfinite(seconds)) return 0.0f;
        const double pos = seconds / blockSeconds_ - 0.5;
        const double last = (double)v.size() - 1.0;
        if (pos < -0.5 || pos > last + 0.5) return 0.0f;
        const double p = std::clamp(pos, 0.0, last);
        const size_t i0 = (size_t)p;
        const size_t i1 = std::min(v.size() - 1, i0 + 1);
        const float t = (float)(p - (double)i0);
        return v[i0] + (v[i1] - v[i0]) * t;
    }

    std::vector<float> level_, onset_, smooth_;
    double blockSeconds_ = 0.0;
};

// ---- Sparks thrown off the waveform at the cursor. Time is cut into
// slots; each slot launches as many sparks as the burst strength then
// asks for, each one's path drawn from a hash of its slot and index. A
// frame evaluates the slots still alive, so the sparks are a pure function
// of the playback time: no state, a seek or a loop just shows other
// sparks, and there are never more than maxSparks().

struct SparkParams {
    double slotSeconds = 1.0 / 60.0;
    double lifetime = 0.9;      // seconds, the longest a spark lives
    float perSlot = 3.0f;       // sparks per slot at strength 1
    int maxPerSlot = 6;
    float speed = 1.6f;         // outward launch speed at strength 1, lane half-heights per second
    float gravity = 4.0f;       // pull back to the wave, lane half-heights per second^2 (< 0 lifts)
    float drift = 60.0f;        // sideways launch speed, points per second
    float forward = 0.35f;      // how far the sideways speed reaches forwards, as a share of backwards
    float minSize = 0.8f;       // points
    float maxSize = 2.2f;
    uint32_t seed = 1;
};

struct Spark {
    double born;        // playback seconds: the cursor's x then is where it starts
    float age;          // 0..1 of its life
    float dx;           // points from where it started, + = the way the cursor goes
    float rise;         // out from the waveform's edge, lane half-heights
    float edge;         // where on the edge it left: 0 = the centre line, 1 = the peak
    float pick;         // 0..1, which lane and side the view puts it on
    float size;         // points
    float alpha;        // 0..1
    float heat;         // 0..1, the strength of the burst it came from
};

inline size_t maxSparks(const SparkParams& p) {
    if (!(p.slotSeconds > 0.0) || !(p.lifetime > 0.0) || p.maxPerSlot <= 0) return 0;
    return ((size_t)std::ceil(p.lifetime / p.slotSeconds) + 1) * (size_t)p.maxPerSlot;
}

// `strengthAt(seconds)` gives the burst strength at a playback time (0 = none)
template <typename Strength>
void sparksAt(double now, const SparkParams& p, Strength strengthAt, std::vector<Spark>& out) {
    out.clear();
    if (maxSparks(p) == 0 || !std::isfinite(now) || now < 0.0) return;
    const int64_t last = (int64_t)std::floor(now / p.slotSeconds);
    const int64_t first = std::max<int64_t>(0, (int64_t)std::floor((now - p.lifetime) / p.slotSeconds));
    const float drag = 2.8f;    // sideways speed halves in a quarter second
    for (int64_t k = first; k <= last; ++k) {
        const double slot = (double)k * p.slotSeconds;
        const float s = std::min(LevelEnvelope::kMaxBurst, std::max(0.0f, (float)strengthAt(slot)));
        if (!(s > 0.0f)) continue;
        const uint32_t key = (uint32_t)k;
        // A fractional count rounds up or down at random, so weak bursts
        // still show now and then instead of never
        const int n = std::min(p.maxPerSlot, (int)(p.perSlot * s + unit(hash(key, p.seed, 0xB5297A4Du))));
        for (int i = 0; i < n; ++i) {
            const uint32_t h = hash(key, p.seed, (uint32_t)i + 1);
            auto r = [h](uint32_t salt) { return unit(hash(h, salt)); };
            const double born = slot + r(1) * p.slotSeconds;
            const float life = (float)p.lifetime * (0.55f + 0.45f * r(2));
            const float a = (float)(now - born);
            if (a < 0.0f || a >= life) continue;
            const float out1 = p.speed * (0.35f + 0.65f * r(3)) * (0.5f + 0.5f * s);
            const float rise = out1 * a - 0.5f * p.gravity * a * a;
            if (rise < 0.0f) continue;   // fell back into the wave
            const float vx = p.drift * (r(4) * (1.0f + p.forward) - 1.0f);
            Spark sp;
            sp.born = born;
            sp.age = a / life;
            sp.dx = vx * (1.0f - std::exp(-drag * a)) / drag;
            sp.rise = rise;
            sp.edge = 0.6f + 0.4f * r(5);
            sp.pick = r(6);
            sp.size = (p.minSize + (p.maxSize - p.minSize) * r(7)) * (1.0f - 0.4f * sp.age);
            sp.alpha = std::pow(1.0f - sp.age, 1.5f);
            sp.heat = std::min(1.0f, s / LevelEnvelope::kMaxBurst * 1.25f);
            out.push_back(sp);
        }
    }
}

// The effects' sparks. Particles: plenty, thrown well clear of the wave.
inline SparkParams particleSparks() {
    SparkParams p;
    p.lifetime = 1.0;
    p.perSlot = 8.0f;
    p.maxPerSlot = 12;
    p.speed = 3.2f;
    p.gravity = 5.5f;
    p.drift = 90.0f;
    p.forward = 0.3f;
    p.minSize = 1.2f;
    p.maxSize = 3.0f;
    p.seed = 0x1F83D9ABu;
    return p;
}

// Earthcrusher: clods and hot bits kicked up behind the cursor, short-lived
inline SparkParams debrisSparks() {
    SparkParams p;
    p.lifetime = 0.55;
    p.perSlot = 2.0f;
    p.maxPerSlot = 4;
    p.speed = 1.8f;
    p.gravity = 7.0f;
    p.drift = 80.0f;
    p.forward = 0.1f;
    p.minSize = 1.2f;
    p.maxSize = 2.8f;
    p.seed = 0x9B05688Cu;
    return p;
}

// Firewall: embers rising off the flames and drifting back (rise and speed
// in view heights rather than lane half-heights)
inline SparkParams emberSparks() {
    SparkParams p;
    p.slotSeconds = 1.0 / 30.0;
    p.lifetime = 1.1;
    p.perSlot = 1.0f;
    p.maxPerSlot = 3;
    p.speed = 0.35f;
    p.gravity = -0.25f;
    p.drift = 26.0f;
    p.forward = 0.2f;
    p.minSize = 0.8f;
    p.maxSize = 1.8f;
    p.seed = 0xE3B0C442u;
    return p;
}

// ---- Firewall: a small heat field stepped like the old demo-scene fire.
// Each step heat rises a row, cools and drifts a column sideways at random,
// a little more often backwards, so the flames lean away from where the
// cursor is going; heat drifting off a side is gone. The cooling comes from
// a smooth noise map that rises with the heat: where it is strong it cuts
// gaps, where it is weak flames climb high, which makes the tongues. The
// bed along the bottom burns hottest around the source column (the cursor).

class FireField {
public:
    static constexpr int kMapRows = 256;    // the cooling map repeats every this many rows
    // How far the flames' middle moves back a row, in cells: measured (the
    // drift alone would be 1/16; cells keeping their heat add to it)
    static constexpr float kLean = 0.2f;

    void resize(int width, int height, int source, uint32_t seed = 0x2545F491u) {
        w_ = std::max(1, std::min(width, kMapRows));
        h_ = std::max(1, height);
        src_ = std::clamp(source, 0, w_ - 1);
        heat_.assign((size_t)w_ * (size_t)h_, 0);
        rng_ = seed ? seed : 1;
        steps_ = 0;
        // Blobs about 8 cells across with finer detail; the lattices repeat
        // every kMapRows rows (and columns). Scaled to a mean of 1 (64 here)
        // so the map shapes the flames without changing their height.
        std::vector<float> mult((size_t)w_ * kMapRows);
        double sum = 0.0;
        for (int y = 0; y < kMapRows; ++y) {
            for (int x = 0; x < w_; ++x) {
                const float n = 0.65f * noise2((float)x / 8.0f, (float)y / 8.0f, kMapRows / 8, seed ^ 0x3C6Eu) +
                                0.35f * noise2((float)x / 4.0f, (float)y / 4.0f, kMapRows / 4, seed ^ 0xA54Fu);
                const float m = std::clamp(0.5f + 0.8f * n, 0.0f, 1.0f);
                const float v = 0.2f + 1.8f * m * m;
                mult[(size_t)y * (size_t)w_ + (size_t)x] = v;
                sum += v;
            }
        }
        const float mean = (float)(sum / (double)mult.size());
        coolMap_.resize(mult.size());
        for (size_t i = 0; i < mult.size(); ++i) {
            coolMap_[i] = (uint8_t)std::clamp((int)std::lround(mult[i] / mean * 64.0f), 0, 255);
        }
    }

    int width() const { return w_; }
    int height() const { return h_; }
    int source() const { return src_; }
    bool empty() const { return heat_.empty(); }
    uint8_t at(int x, int y) const { return heat_[(size_t)y * (size_t)w_ + (size_t)x]; }   // y = 0: bottom

    // One step; `fuel` (0..1.5: level and beat) sets how high the flames
    // climb. It changes the cooling of every row at once: changing the
    // bed's heat instead would rise through the field as bands.
    void step(float fuel) {
        if (heat_.empty()) return;
        fuel = std::clamp(std::isfinite(fuel) ? fuel : 0.0f, 0.0f, 1.5f);
        // The hottest flames would climb 55-125 % of the height before they
        // cool below visible (heat ~40), at a mean cooling of 215 / reach a
        // row; the cooling map stops most of them well short of that. The
        // largest cooling, twice the mean, in 1/256ths: whole units would
        // make the height jump in steps instead of following the fuel.
        const float reach = std::max(8.0f, (float)h_ * std::min(1.25f, 0.55f + 0.45f * fuel));
        const uint32_t coolMax = (uint32_t)std::lround(2.0f * 215.0f / reach * 256.0f);
        // From the top down, so each row reads the row below as it was. Each
        // cell's heat moves up into the cell above it or beside that: left
        // 3/16 of the time, right 2/16, so the flames drift backwards. A cell
        // nothing moves into keeps its heat for a step (copying one cell into
        // two instead would smear rows sideways). The map row follows the
        // heat up, so a parcel keeps meeting the same blob of cooling.
        const int shift = (int)(steps_ % (uint64_t)kMapRows);
        for (int y = h_ - 1; y >= 1; --y) {
            uint8_t* row = &heat_[(size_t)y * (size_t)w_];
            const uint8_t* below = &heat_[(size_t)(y - 1) * (size_t)w_];
            const uint8_t* map = &coolMap_[(size_t)(((y - shift) % kMapRows + kMapRows) % kMapRows) * (size_t)w_];
            for (int x = 0; x < w_; ++x) {
                const uint32_t r = next();
                const uint32_t d = (r >> 20) & 15;
                const int to = x + (d < 3 ? -1 : d < 14 ? 0 : 1);
                if (to < 0 || to >= w_) continue;
                // random 0..1 (8 bits) x coolMax (8.8) x map (64 = 1), rounded
                const int c = (int)(((r & 0xFF) * coolMax * map[to] + (1u << 21)) >> 22);
                row[to] = (uint8_t)std::max(0, (int)below[x] - c);
            }
        }
        // The bed: full heat around the source, tapering to nothing well
        // inside the sides (a flame cut by the field's edge would show it),
        // flickering cell by cell
        for (int x = 0; x < w_; ++x) {
            const float d = (float)(x - src_) / ((float)w_ * 0.2f);
            const float flicker = 0.85f + 0.15f * unit(next());
            heat_[(size_t)x] = (uint8_t)std::clamp(255.0f * 1.3f * std::exp(-d * d) * flicker, 0.0f, 255.0f);
        }
        ++steps_;
    }

    // Premultiplied RGBA for a heat: clear when cool, then deep red,
    // orange, yellow, nearly white at the hottest
    static const std::array<uint8_t, 4>& colour(uint8_t heat) {
        static const std::array<std::array<uint8_t, 4>, 256> table = [] {
            std::array<std::array<uint8_t, 4>, 256> t{};
            struct Key { float at, r, g, b; };
            const Key keys[] = {
                { 0.00f, 0.35f, 0.02f, 0.00f }, { 0.30f, 0.62f, 0.06f, 0.01f },
                { 0.50f, 0.92f, 0.28f, 0.03f }, { 0.70f, 1.00f, 0.58f, 0.10f },
                { 0.86f, 1.00f, 0.84f, 0.38f }, { 1.00f, 1.00f, 0.97f, 0.82f },
            };
            for (int i = 0; i < 256; ++i) {
                const float h = (float)i / 255.0f;
                size_t k = 0;
                while (k + 2 < std::size(keys) && h > keys[k + 1].at) ++k;
                const Key& a = keys[k];
                const Key& b = keys[k + 1];
                const float f = std::clamp((h - a.at) / (b.at - a.at), 0.0f, 1.0f);
                const float alpha = smoothstep(0.10f, 0.42f, h);
                const float rgb[3] = { a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f };
                for (int c = 0; c < 3; ++c) t[i][c] = (uint8_t)std::lround(rgb[c] * alpha * 255.0f);
                t[i][3] = (uint8_t)std::lround(alpha * 255.0f);
            }
            return t;
        }();
        return table[heat];
    }

    // A heat grid (`width` x `height`, row 0 at the bottom) as premultiplied
    // RGBA, top row first (image order), each cell softened with its four
    // neighbours so single cells don't show
    static void paintHeat(const uint8_t* heat, int width, int height, uint8_t* rgba, size_t bytesPerRow) {
        auto at = [&](int x, int y) {
            return (x < 0 || x >= width || y < 0 || y >= height) ? 0 : (int)heat[(size_t)y * (size_t)width + (size_t)x];
        };
        for (int y = 0; y < height; ++y) {
            uint8_t* out = rgba + (size_t)(height - 1 - y) * bytesPerRow;
            for (int x = 0; x < width; ++x) {
                const int soft = (4 * at(x, y) + at(x - 1, y) + at(x + 1, y) + at(x, y - 1) + at(x, y + 1)) / 8;
                const auto& c = colour((uint8_t)soft);
                std::copy(c.begin(), c.end(), out + (size_t)x * 4);
            }
        }
    }

    // The field as premultiplied RGBA, top row first
    void paint(uint8_t* rgba, size_t bytesPerRow) const {
        if (!heat_.empty()) paintHeat(heat_.data(), w_, h_, rgba, bytesPerRow);
    }

    const uint8_t* data() const { return heat_.data(); }

private:
    uint32_t next() {   // xorshift32
        rng_ ^= rng_ << 13;
        rng_ ^= rng_ >> 17;
        rng_ ^= rng_ << 5;
        return rng_;
    }

    int w_ = 0, h_ = 0, src_ = 0;
    std::vector<uint8_t> heat_;
    std::vector<uint8_t> coolMap_;  // w_ x kMapRows, 64 = mean cooling
    uint32_t rng_ = 1;
    uint64_t steps_ = 0;
};

// ---- Firewall's row of fires along the played part. They all show the one
// simulated field, each as it was a different number of steps ago, so
// neighbours flicker apart for the cost of one simulation.

class FireHistory {
public:
    static constexpr int kFrames = 64;      // ~0.5 s of steps at 120 a second

    void reset(int width, int height) {
        w_ = std::max(1, width);
        h_ = std::max(1, height);
        frames_.assign((size_t)kFrames * (size_t)w_ * (size_t)h_, 0);
        newest_ = 0;
        count_ = 0;
    }

    // Keeps the field as it is now; a field of another size starts over
    void push(const FireField& field) {
        if (field.empty()) return;
        if (field.width() != w_ || field.height() != h_ || frames_.empty()) reset(field.width(), field.height());
        newest_ = (newest_ + 1) % kFrames;
        std::copy(field.data(), field.data() + (size_t)w_ * (size_t)h_, slot(newest_));
        count_ = std::min(count_ + 1, kFrames);
    }

    int width() const { return w_; }
    int height() const { return h_; }
    int count() const { return count_; }

    // The field `age` steps back (0 = the latest), the oldest kept when
    // there are fewer; null before the first push
    const uint8_t* frame(int age) const {
        if (count_ == 0) return nullptr;
        age = std::clamp(age, 0, count_ - 1);
        return slot((newest_ - age + kFrames) % kFrames);
    }

private:
    uint8_t* slot(int i) { return &frames_[(size_t)i * (size_t)w_ * (size_t)h_]; }
    const uint8_t* slot(int i) const { return &frames_[(size_t)i * (size_t)w_ * (size_t)h_]; }

    int w_ = 0, h_ = 0;
    std::vector<uint8_t> frames_;
    int newest_ = 0, count_ = 0;
};

struct FirePlace {
    double x;           // where it burns hottest, points
    float scale;        // its height, 0..1 of the field's
    float width;        // its width, 0..1 of the field's: smaller fires, not squat ones
    float heat;         // 0..1 of the field's heat: further back they burn lower and redder
    int age;            // steps back in the history
    bool mirror;        // drawn the other way round, for variety
};

// The fires from `from` up to the cursor (points). One every `spacing`
// points counted from the track's start, so they stay put on the track as
// the cursor moves on, each nudged a little so the row isn't regular. Each
// as big as the track is loud there (`levelAt(x)`, 0..1), and bigger and
// hotter the nearer the cursor; none past it.
template <typename LevelAt>
void layoutFires(double trackStart, double from, double cursor, double spacing, LevelAt levelAt,
                 std::vector<FirePlace>& out) {
    out.clear();
    if (!(spacing >= 1.0) || !std::isfinite(trackStart) || !std::isfinite(from) || !std::isfinite(cursor)) return;
    constexpr double kNearCursor = 90.0;        // points over which fires fall to the row's height
    constexpr size_t kMaxFires = 4096;
    const double first = std::max(0.0, std::floor((from - trackStart) / spacing) - 1.0);
    const double last = std::floor((cursor - trackStart) / spacing);
    for (double k = first; k <= last && out.size() < kMaxFires; k += 1.0) {
        const uint32_t key = (uint32_t)(int64_t)k;
        const double x = trackStart + (k + 0.5 + 0.7 * (unit(hash(key, 0xF17Eu)) - 0.5)) * spacing;
        if (x > cursor || x < from - spacing) continue;
        const float level = std::clamp((float)levelAt(x), 0.0f, 1.0f);
        const float near = (float)std::exp(-(cursor - x) / kNearCursor);
        FirePlace f;
        f.x = x;
        // Sizes jittered by up to 20 %, so neighbours differ in height too
        const float jitter = 0.8f + 0.4f * unit(hash(key, 0x51Eu));
        f.scale = std::min(1.0f, (0.2f + 0.8f * level) * (0.5f + 0.5f * near) * jitter);
        f.width = 0.3f + 0.7f * f.scale;
        f.heat = std::min(1.0f, 0.55f + 0.2f * level + 0.35f * near);
        const uint32_t pick = hash(key, 0xA9Eu);
        f.age = (int)(pick % (uint32_t)FireHistory::kFrames);
        f.mirror = (pick >> 16) & 1;
        out.push_back(f);
    }
}

struct FireColumn {
    int base;           // cell of the field's source column
    float scale;        // height, 0..1 of the field's
    float width;        // width, 0..1 of the field's
    float heat;         // 0..1 of the field's heat
    int age;            // steps back in the history
    bool mirror;
};

// The fires side by side as one heat grid of field-sized cells, `outW` x
// `outH` (row 0 at the bottom): each the field as it was `age` steps ago,
// stood upright (they stay where they are, so they don't lean like the
// cursor's), shrunk to its size, its heat scaled, its source column at
// `base`. The hottest wins where they overlap.
inline void composeFires(const FireHistory& history, int source, const std::vector<FireColumn>& fires, int outW,
                         int outH, std::vector<uint8_t>& heat) {
    heat.assign((size_t)std::max(0, outW) * (size_t)std::max(0, outH), 0);
    if (outW <= 0 || outH <= 0 || history.count() == 0) return;
    const int fw = history.width(), fh = history.height();
    // Upright, a flame reaches this far either side of its base, in field cells
    const float reach = std::max((float)source, (float)(fw - source)) + FireField::kLean * (float)fh;
    std::vector<int> fromX;
    for (const FireColumn& f : fires) {
        const float dir = f.mirror ? -1.0f : 1.0f;
        const uint8_t* frame = history.frame(f.age);
        const float scale = std::clamp(f.scale, 0.0f, 1.0f);
        const float width = std::clamp(f.width, 0.05f, 1.0f);
        const uint32_t gain = (uint32_t)std::lround(std::clamp(f.heat, 0.0f, 1.0f) * 256.0f);
        const int rows = std::min(outH, (int)std::lround(scale * (float)fh));
        if (!frame || rows < 1 || gain == 0) continue;
        const int extent = (int)std::ceil(reach * width);
        const int x0 = std::max(0, f.base - extent), x1 = std::min(outW, f.base + extent + 1);
        if (x1 <= x0) continue;
        // The field column under each cell at the bottom, worked out once
        fromX.resize((size_t)(x1 - x0));
        for (int ox = x0; ox < x1; ++ox) {
            fromX[(size_t)(ox - x0)] = source + (int)std::floor(dir * (float)(ox - f.base) / width);
        }
        for (int oy = 0; oy < rows; ++oy) {
            // A row of the fire this far up its own height, moved back by the
            // lean it has there; only the cells that land in the field
            const int fy = std::min(fh - 1, (int)((float)oy / scale));
            const int lean = (int)std::lround(FireField::kLean * (float)fy);
            const float lo = (float)(-source + lean) * width, hi = (float)(fw - source + lean) * width;
            const int a = std::max(x0, f.base + (int)std::floor(f.mirror ? -hi : lo) - 1);
            const int b = std::min(x1, f.base + (int)std::ceil(f.mirror ? -lo : hi) + 1);
            const uint8_t* src = frame + (size_t)fy * (size_t)fw;
            uint8_t* dst = &heat[(size_t)oy * (size_t)outW];
            for (int ox = a; ox < b; ++ox) {
                const int fx = fromX[(size_t)(ox - x0)] - lean;
                if (fx < 0 || fx >= fw) continue;
                dst[ox] = std::max(dst[ox], (uint8_t)((src[fx] * gain) >> 8));
            }
        }
    }
}

// ---- Earthcrusher's colours, from the waveform's, so what it leaves behind
// reads as the same material burnt: darker, duller pieces and nearly black
// cracks in the wave's hue, clods of the wave colour, a bright vivid glow and
// a nearly white core where it is hot. A grey wave stays grey.

struct EarthShades {
    theme::RGB plate;   // the baked pieces
    theme::RGB crack;   // the cracks, the fissure's edges
    theme::RGB clod;    // bits kicked up
    theme::RGB ember;   // glowing cracks, the fissure's glow
    theme::RGB core;    // the fissure's core, the hottest embers
};

inline EarthShades earthShades(const theme::RGB& wave) {
    const theme::Oklch w = theme::toOklch(wave);
    const bool grey = w.C < 0.02f;
    EarthShades s;
    s.plate = theme::fromOklch({ std::clamp(w.L * 0.5f, 0.2f, 0.4f), w.C * 0.7f, w.h });
    s.crack = theme::fromOklch({ 0.13f, w.C * 0.4f, w.h });
    s.clod = theme::fromOklch({ std::clamp(w.L * 0.8f, 0.3f, 0.7f), w.C * 0.8f, w.h });
    s.ember = theme::fromOklch({ 0.74f, grey ? w.C : std::max(w.C, 0.16f), w.h });
    s.core = theme::fromOklch({ 0.96f, std::min(w.C, 0.05f), w.h });
    return s;
}

// ---- Earthcrusher: dried, broken earth. A square tile of jittered-grid
// Voronoi cells (the pieces), repeating in both directions; the cracks run
// along the cells' borders, wobbled by noise, with finer cracks inside
// some pieces.

struct CrackTile {
    int size = 0;                   // pixels a side
    std::vector<uint8_t> crack;     // 255 on a crack, falling off across its width
    std::vector<uint8_t> glow;      // the main cracks again, wider and softer: embers
    std::vector<uint8_t> plate;     // shade of the piece, darker towards its edges
};

namespace detail {

struct CellHit {
    float edge;         // distance to the nearest border, cell units
    uint32_t cell;      // hash of the nearest cell
};

// Nearest cell and the distance to its border at (x, y), in cell units, on
// a grid of n x n cells that wraps
inline CellHit voronoi(float x, float y, int n, uint32_t seed) {
    auto wrap = [n](int i) { return (uint32_t)(((i % n) + n) % n); };
    auto point = [&](int i, int j, float& px, float& py) {
        const uint32_t wi = wrap(i), wj = wrap(j);
        px = (float)i + 0.12f + 0.76f * unit(hash(wi, wj, seed));
        py = (float)j + 0.12f + 0.76f * unit(hash(wi, wj, seed ^ 0x5BD1E995u));
    };
    const int cx = (int)std::floor(x), cy = (int)std::floor(y);
    float best = 1e9f, ax = 0, ay = 0;
    int bi = cx, bj = cy;
    for (int j = cy - 1; j <= cy + 1; ++j) {
        for (int i = cx - 1; i <= cx + 1; ++i) {
            float px, py;
            point(i, j, px, py);
            const float d = (px - x) * (px - x) + (py - y) * (py - y);
            if (d < best) { best = d; ax = px; ay = py; bi = i; bj = j; }
        }
    }
    // The nearest border: the bisector with each neighbour of that cell
    float edge = 1e9f;
    for (int j = bj - 2; j <= bj + 2; ++j) {
        for (int i = bi - 2; i <= bi + 2; ++i) {
            if (i == bi && j == bj) continue;
            float px, py;
            point(i, j, px, py);
            const float nx = px - ax, ny = py - ay;
            const float len = std::sqrt(nx * nx + ny * ny);
            if (len <= 1e-6f) continue;
            const float d = ((ax + px) * 0.5f - x) * nx / len + ((ay + py) * 0.5f - y) * ny / len;
            edge = std::min(edge, std::max(0.0f, d));
        }
    }
    return { edge, hash(wrap(bi), wrap(bj), seed + 1) };
}

} // namespace detail

// `cells` pieces across the tile; the fine cracks split each piece in about
// four, half of them showing
inline CrackTile makeCrackTile(int size, int cells, uint32_t seed) {
    CrackTile t;
    if (size <= 0 || cells <= 0) return t;
    t.size = size;
    const size_t n = (size_t)size * (size_t)size;
    t.crack.resize(n);
    t.glow.resize(n);
    t.plate.resize(n);
    const float cellPx = (float)size / (float)cells;
    const float width = 0.075f;         // main crack half-width, cell units
    const float fineWidth = 0.05f;      // in fine-cell units
    for (int py = 0; py < size; ++py) {
        for (int px = 0; px < size; ++px) {
            float x = ((float)px + 0.5f) / cellPx, y = ((float)py + 0.5f) / cellPx;
            // Wobble, on a lattice twice as fine as the cells so it repeats with them
            x += 0.10f * noise2(x * 2.0f, y * 2.0f, cells * 2, seed ^ 0xA1u);
            y += 0.10f * noise2(x * 2.0f, y * 2.0f, cells * 2, seed ^ 0xB2u);
            const detail::CellHit main = detail::voronoi(x, y, cells, seed);
            const detail::CellHit fine = detail::voronoi(x * 2.0f, y * 2.0f, cells * 2, seed ^ 0xC3u);
            const float mainCrack = 1.0f - smoothstep(width * 0.3f, width, main.edge);
            const bool fineShows = unit(hash(fine.cell, 7u)) < 0.5f;
            const float fineCrack = fineShows ? 0.55f * (1.0f - smoothstep(fineWidth * 0.3f, fineWidth, fine.edge)) : 0.0f;
            const float glow = 1.0f - smoothstep(0.0f, width * 3.0f, main.edge);
            const float shade = (0.3f + 0.7f * unit(main.cell)) * (0.5f + 0.5f * smoothstep(0.0f, 0.3f, main.edge));
            const size_t i = (size_t)py * (size_t)size + (size_t)px;
            t.crack[i] = (uint8_t)std::lround(std::max(mainCrack, fineCrack) * 255.0f);
            t.glow[i] = (uint8_t)std::lround(glow * glow * 255.0f);
            t.plate[i] = (uint8_t)std::lround(shade * 255.0f);
        }
    }
    return t;
}

// Earthcrusher's fades across the zone behind the cursor, u = 0 at the
// cursor .. 1 at the far end: the scorch fades out, the embers die sooner
inline float scorchFade(float u) {
    u = std::clamp(u, 0.0f, 1.0f);
    return std::pow(1.0f - smoothstep(0.0f, 1.0f, u), 1.2f);
}
inline float emberFade(float u) {
    u = std::clamp(u, 0.0f, 1.0f);
    return (1.0f - u) * (1.0f - u);
}

// Earthcrusher's cursor: a vertex every `step` points up a line `height`
// long (the inner ones moved up or down a little so the segments differ),
// offset sideways within +-amplitude: a zigzag that morphs smoothly, with
// part of it re-rolled in jumps a few times a second. Points are (dx, y).
inline void jaggedLine(float height, float step, float amplitude, double time, uint32_t seed,
                       std::vector<std::array<float, 2>>& points) {
    points.clear();
    if (!(height > 0.0f) || !(step > 0.0f) || !std::isfinite(time)) return;
    amplitude = std::max(0.0f, amplitude);
    const int n = std::max(1, (int)std::ceil(height / step));
    const float t = (float)std::fmod(time, 1000.0);     // float keeps its precision
    const uint32_t tick = (uint32_t)(int64_t)std::floor(time * 6.0);
    for (int j = 0; j <= n; ++j) {
        float y = std::min(height, (float)j * step);
        if (j > 0 && j < n) y = std::min(height, y + (unit(hash((uint32_t)j, seed, 3u)) - 0.5f) * step * 0.8f);
        const float drift = noise1((float)j * 0.45f + t * 1.7f, seed);
        const float zig = (j & 1) ? 1.0f : -1.0f;
        const float jolt = unit(hash((uint32_t)j, tick, seed)) * 2.0f - 1.0f;
        const float dx = amplitude * (0.55f * drift + 0.15f * zig + 0.3f * jolt);
        points.push_back({ std::clamp(dx, -amplitude, amplitude), y });
    }
}

} // namespace waveseek::fx
