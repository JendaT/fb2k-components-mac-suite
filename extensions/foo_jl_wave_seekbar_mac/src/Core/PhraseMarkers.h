//
//  PhraseMarkers.h
//  foo_wave_seekbar_mac
//
//  Phrase markers from a beat grid served by BPM Analyzer (jl_beatgrid):
//  where each 16- or 32-beat phrase starts, its state by the shared rule
//  (jl_classify_phrase), and how far to thin them so markers stay apart.
//  Header-only, tested standalone; the view only draws what this returns.
//

#pragma once

#include "../../../../shared/jl_beatgrid_types.h"

#include <algorithm>
#include <cmath>
#include <vector>

namespace waveseek {

// A track's grid as fetched from the provider
struct PhraseGrid {
    jl_beatgrid_summary summary{};
    std::vector<jl_beat_region> regions;
    std::vector<jl_bar_stat> bars;
};

// Markers closer than this double the phrase length (32 -> 64 -> 128 ...)
constexpr double kMinPhraseSpacing = 6.0;
constexpr int kMaxPhraseBeats = 1024;

// The phrase length to draw: `phraseBeats` (16 or 32), doubled while
// neighbouring markers would be under kMinPhraseSpacing points apart in a
// waveform `widthPoints` wide showing 1 / zoom of the track
inline int thinnedPhraseBeats(int phraseBeats, double bpm, double durationSeconds, double widthPoints,
                              double zoom = 1.0) {
    if (!(bpm > 0.0) || !(durationSeconds > 0.0) || !(widthPoints > 0.0) || phraseBeats <= 0) return phraseBeats;
    const double pointsPerBeat = 60.0 / bpm / durationSeconds * widthPoints * std::max(1.0, zoom);
    int beats = phraseBeats;
    while (beats < kMaxPhraseBeats && beats * pointsPerBeat < kMinPhraseSpacing) beats *= 2;
    return beats;
}

struct PhraseMarker {
    long phrase = 0;                // 0-based phrase index from the first phrase start
    long startBar = 0;              // 0-based bar of the master grid (bars start on its bar phase)
    double seconds = 0.0;           // where the phrase starts
    jl_phrase_state state = jl_phrase_locked;
    int offsetMs = 0;               // median signed offset of its bars
    double reanchorSeconds = NAN;   // first beat of a new grid inside it, if any
};

// The bar a phrase count starts on: the provider's phrase phase when it is
// confident, else beat 0's bar
inline long firstPhraseBar(const jl_beatgrid_summary &s, int barsPerPhrase) {
    if (s.phrase_phase_bars < 0 || s.phrase_confidence < jl_phrase_min_confidence || barsPerPhrase <= 0) return 0;
    // phrase_phase_bars is for 32-beat phrases; it also starts every shorter phrase
    return s.phrase_phase_bars % barsPerPhrase;
}

// Every marker over the track, `phraseBeats` (a multiple of 4) apart
inline std::vector<PhraseMarker> phraseMarkers(const PhraseGrid &grid, int phraseBeats) {
    std::vector<PhraseMarker> out;
    const double bpm = grid.summary.bpm;
    const int barsPerPhrase = std::max(1, phraseBeats / 4);
    if (!(bpm > 0.0) || grid.bars.empty()) return out;
    const double barSeconds = 4 * 60.0 / bpm;
    const double barsFrom = jl_beat_time(grid.summary, jl_first_bar_beat(grid.summary));
    const long bars = static_cast<long>(grid.bars.size());
    long phrase = 0;
    for (long start = firstPhraseBar(grid.summary, barsPerPhrase); start < bars; start += barsPerPhrase, ++phrase) {
        const long count = std::min<long>(barsPerPhrase, bars - start);
        PhraseMarker m;
        m.phrase = phrase;
        m.startBar = start;
        m.seconds = barsFrom + static_cast<double>(start) * barSeconds;
        m.state = jl_classify_phrase(grid.bars.data() + start, static_cast<size_t>(count));

        std::vector<int> offsets;
        for (long b = start; b < start + count; ++b) offsets.push_back(grid.bars[static_cast<size_t>(b)].offset_ms);
        std::nth_element(offsets.begin(), offsets.begin() + static_cast<std::ptrdiff_t>(offsets.size() / 2), offsets.end());
        m.offsetMs = offsets[offsets.size() / 2];

        if (m.state == jl_phrase_reanchor) {
            // The new grid's first beat: a stable region starting inside the
            // phrase, else the flagged bar
            const double end = m.seconds + static_cast<double>(count) * barSeconds;
            for (const jl_beat_region &r : grid.regions) {
                if (r.beat_count >= jl_beatgrid_min_stable_beats && !(r.flags & jl_region_quiet) &&
                    r.start_seconds >= m.seconds - 1e-6 && r.start_seconds < end) {
                    m.reanchorSeconds = r.start_seconds;
                    break;
                }
            }
            for (long b = start; std::isnan(m.reanchorSeconds) && b < start + count; ++b) {
                if (grid.bars[static_cast<size_t>(b)].flags & jl_bar_region_start) {
                    m.reanchorSeconds = barsFrom + static_cast<double>(b) * barSeconds;
                }
            }
        }
        out.push_back(m);
    }
    return out;
}

// Share of phrases that are Locked, for the summary badge
inline double lockedPhraseShare(const std::vector<PhraseMarker> &markers) {
    if (markers.empty()) return 0.0;
    size_t locked = 0;
    for (const PhraseMarker &m : markers) locked += m.state == jl_phrase_locked;
    return static_cast<double>(locked) / static_cast<double>(markers.size());
}

} // namespace waveseek
