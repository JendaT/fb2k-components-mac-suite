#pragma once

//
// jl_beatgrid_types.h — beat grid values shared by BPM Analyzer (the
// provider) and the components that draw them (Waveform Seekbar), plus the
// phrase-marker rules, so every consumer colours a phrase the same way.
//
// Plain C++17 with no foobar2000 SDK: the BPM component's analysis core and
// the consumers' standalone unit tests include it directly.
// jl_beatgrid_api.h adds the service on top.
//
// Grid model: one master grid per track, beat j at
// anchor_seconds + j * 60 / bpm. Bars of 4 beats start on beat bar_phase
// (beat 0 when bar_phase is -1, unknown): bar i covers beats
// jl_first_bar_beat() + 4i .. + 3, and so do the per-bar statistics, which
// say how well the detected beats sit on the grid. A phrase of 16 or 32
// beats aggregates 4 or 8 bars at draw time, starting on bar
// phrase_phase_bars (mod 8) when phrase_confidence allows.
//
// ABI: these structs cross the dylib boundary inside pfc::array_t (see
// jl_beatgrid_api.h). Their layouts are FROZEN for the service GUID there:
// changing a field means a new GUID, so an older provider reads as missing
// instead of misbehaving. Reserved bytes are zero.
//

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

// A stretch of detected beats that fits one straight grid
struct jl_beat_region {
    double start_seconds;       // first beat
    double beat_seconds;
    uint32_t beat_count;        // intervals; under jl_beatgrid_min_stable_beats = unstable
    uint32_t flags;             // jl_region_*
};
enum : uint32_t {
    jl_region_quiet = 1,        // most beats without pulse (a silence the tracker ran through)
};
inline constexpr uint32_t jl_beatgrid_min_stable_beats = 16;

// One bar (4 beats) of the master grid
struct jl_bar_stat {
    int8_t offset_ms;           // median signed offset of the detected beats from their grid beats, clamped
    uint8_t matched;            // grid beats with a detected beat within 25 ms, 0..4
    uint8_t pulse;              // mean onset energy; jl_pulse_unit = the track's median bar
    uint8_t flags;              // jl_bar_*
};
enum : uint8_t {
    // A stable region with another phase or tempo than the one before it
    // begins in this bar (an edit, a re-recorded section, a tempo change)
    jl_bar_region_start = 1,
};
inline constexpr int jl_pulse_unit = 64;

enum jl_beatgrid_source : uint8_t {
    jl_beatgrid_source_classic = 0,     // onset envelope + dynamic programming
    jl_beatgrid_source_beat_this = 1,   // Beat This! network (later)
};

struct jl_beatgrid_summary {
    double bpm;
    double anchor_seconds;      // master-grid beat 0: the first grid beat at or after 0
    float tempo_strength;       // 0..1; under jl_beatgrid_uncertain_strength draw neutral
    int8_t bar_phase;           // beat index mod 4 that starts a bar; -1 unknown
    int8_t phrase_phase_bars;   // bar index mod 8 that starts a 32-beat phrase; -1 unknown
    uint8_t reserved0[2];
    float phrase_confidence;    // 0..1; under jl_phrase_min_confidence don't claim phrase starts
    uint8_t source;             // jl_beatgrid_source
    uint8_t reserved1[3];
};
inline constexpr float jl_beatgrid_uncertain_strength = 0.3f;
inline constexpr float jl_phrase_min_confidence = 0.15f;

static_assert(sizeof(jl_beat_region) == 24, "jl_beat_region layout is frozen");
static_assert(sizeof(jl_bar_stat) == 4, "jl_bar_stat layout is frozen");
static_assert(sizeof(jl_beatgrid_summary) == 32, "jl_beatgrid_summary layout is frozen");

inline double jl_beat_time(const jl_beatgrid_summary &grid, long beat) {
    return grid.bpm > 0.0 ? grid.anchor_seconds + static_cast<double>(beat) * 60.0 / grid.bpm : 0.0;
}

// The beat bar 0 (and bars[0] of the statistics) starts on
inline long jl_first_bar_beat(const jl_beatgrid_summary &grid) {
    return grid.bar_phase > 0 ? grid.bar_phase : 0;
}

// ---------------------------------------------------------------------------
// Phrase markers
// ---------------------------------------------------------------------------

// How a phrase marker is drawn
enum jl_phrase_state : uint8_t {
    jl_phrase_locked,           // on the grid
    jl_phrase_drifting,         // off by 10-25 ms, or 40-75% of beats matched
    jl_phrase_broken,           // off by more, or fewer matched, with pulse present
    jl_phrase_no_pulse,         // a beatless stretch: never counted as broken
    jl_phrase_reanchor,         // a new grid starts in the phrase
};

// Starting defaults, to be tuned against a library
inline constexpr double jl_phrase_locked_ms = 10.0;
inline constexpr double jl_phrase_drifting_ms = 25.0;
inline constexpr double jl_phrase_locked_share = 0.75;
inline constexpr double jl_phrase_broken_share = 0.40;
inline constexpr double jl_phrase_no_pulse_level = 0.25;   // of jl_pulse_unit

// The state of the phrase made of `count` bars (4 for 16 beats, 8 for 32).
// Re-anchor wins, then no pulse (most bars under a quarter of the median),
// then the median absolute offset and the share of matched beats decide.
inline jl_phrase_state jl_classify_phrase(const jl_bar_stat *bars, size_t count) {
    if (!bars || count == 0) return jl_phrase_no_pulse;
    size_t quiet = 0, matched = 0;
    bool region_start = false;
    std::vector<double> offsets;
    offsets.reserve(count);
    for (size_t i = 0; i < count; i++) {
        region_start |= (bars[i].flags & jl_bar_region_start) != 0;
        if (bars[i].pulse < jl_phrase_no_pulse_level * jl_pulse_unit) quiet++;
        matched += bars[i].matched;
        offsets.push_back(std::fabs(static_cast<double>(bars[i].offset_ms)));
    }
    if (region_start) return jl_phrase_reanchor;
    if (quiet * 2 > count) return jl_phrase_no_pulse;

    const size_t mid = offsets.size() / 2;
    std::nth_element(offsets.begin(), offsets.begin() + static_cast<std::ptrdiff_t>(mid), offsets.end());
    double offset = offsets[mid];
    if (offsets.size() % 2 == 0) {
        offset = 0.5 * (offset + *std::max_element(offsets.begin(), offsets.begin() + static_cast<std::ptrdiff_t>(mid)));
    }
    const double share = static_cast<double>(matched) / static_cast<double>(count * 4);
    if (offset > jl_phrase_drifting_ms || share < jl_phrase_broken_share) return jl_phrase_broken;
    if (offset > jl_phrase_locked_ms || share < jl_phrase_locked_share) return jl_phrase_drifting;
    return jl_phrase_locked;
}
