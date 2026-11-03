//
//  PhraseMarkers.h
//  foo_wave_seekbar_mac
//
//  Phrase markers from a beat grid served by BPM Analyzer (jl_beatgrid):
//  where each 16- or 32-beat phrase starts, its state by the shared rule
//  (jl_classify_phrase), and how far to thin them so markers stay apart.
//  On the master grid, or following the grid where it changes: section by
//  section, each counting its own phrases on its own tempo.
//  Header-only, tested standalone; the view only draws what this returns.
//

#pragma once

#include "../../../../shared/jl_beatgrid_types.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <vector>

namespace waveseek {

// A track's grid as fetched from the provider
struct PhraseGrid {
    jl_beatgrid_summary summary{};
    std::vector<jl_beat_region> regions;
    std::vector<jl_bar_stat> bars;
    // Section by section (get_sections); one section, or none fetched, when
    // the master grid holds throughout
    std::vector<jl_grid_section> sections;
    std::vector<jl_bar_stat> sectionBars;

    bool hasSections() const { return sections.size() > 1; }
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

// The tempo that sets the thinning: the fastest section's when following
// the sections, so markers stay apart in all of them
inline double densestBpm(const PhraseGrid &grid, bool follow) {
    double bpm = grid.summary.bpm;
    if (follow && grid.hasSections()) {
        for (const jl_grid_section &s : grid.sections) bpm = std::max(bpm, s.bpm);
    }
    return bpm;
}

struct PhraseMarker {
    long phrase = 0;                // 0-based phrase index from its grid's first phrase start; -1 where a section starts
    long startBar = 0;              // 0-based bar of its grid (bars start on its bar phase)
    size_t section = 0;             // following the sections: which one; else 0
    double seconds = 0.0;           // where the phrase starts
    jl_phrase_state state = jl_phrase_locked;
    int offsetMs = 0;               // median signed offset of its bars
    double reanchorSeconds = NAN;   // first beat of a new grid inside it, if any
    double bpm = 0.0;               // its grid's tempo
};

// The bar a phrase count starts on: the grid's phrase phase when it is
// confident, else the first bar
inline long firstPhraseBar(int phrasePhaseBars, float phraseConfidence, int barsPerPhrase) {
    if (phrasePhaseBars < 0 || phraseConfidence < jl_phrase_min_confidence || barsPerPhrase <= 0) return 0;
    // phrase_phase_bars is for 32-beat phrases; it also starts every shorter phrase
    return phrasePhaseBars % barsPerPhrase;
}

inline long firstPhraseBar(const jl_beatgrid_summary &s, int barsPerPhrase) {
    return firstPhraseBar(s.phrase_phase_bars, s.phrase_confidence, barsPerPhrase);
}

namespace detail {

// The markers of one grid's phrases: bars[0..count) from barsFrom, a bar
// every barSeconds, phrases from firstBar, none starting at or after `end`
inline void gridPhrases(std::vector<PhraseMarker> &out, const jl_bar_stat *bars, long count, double barsFrom,
                        double barSeconds, long firstBar, int barsPerPhrase, double end, size_t section, double bpm,
                        const std::vector<jl_beat_region> *regions) {
    long phrase = 0;
    for (long start = firstBar; start < count; start += barsPerPhrase, ++phrase) {
        const double seconds = barsFrom + static_cast<double>(start) * barSeconds;
        if (seconds >= end) break;
        const long n = std::min<long>(barsPerPhrase, count - start);
        PhraseMarker m;
        m.phrase = phrase;
        m.startBar = start;
        m.section = section;
        m.seconds = seconds;
        m.bpm = bpm;
        m.state = jl_classify_phrase(bars + start, static_cast<size_t>(n));

        std::vector<int> offsets;
        for (long b = start; b < start + n; ++b) offsets.push_back(bars[b].offset_ms);
        std::nth_element(offsets.begin(), offsets.begin() + static_cast<std::ptrdiff_t>(offsets.size() / 2), offsets.end());
        m.offsetMs = offsets[offsets.size() / 2];

        if (m.state == jl_phrase_reanchor) {
            // The new grid's first beat: a stable region starting inside the
            // phrase, else the flagged bar
            const double phraseEnd = m.seconds + static_cast<double>(n) * barSeconds;
            for (size_t i = 0; regions && i < regions->size(); ++i) {
                const jl_beat_region &r = (*regions)[i];
                if (r.beat_count >= jl_beatgrid_min_stable_beats && !(r.flags & jl_region_quiet) &&
                    r.start_seconds >= m.seconds - 1e-6 && r.start_seconds < phraseEnd) {
                    m.reanchorSeconds = r.start_seconds;
                    break;
                }
            }
            for (long b = start; std::isnan(m.reanchorSeconds) && b < start + n; ++b) {
                if (bars[b].flags & jl_bar_region_start) m.reanchorSeconds = barsFrom + static_cast<double>(b) * barSeconds;
            }
        }
        out.push_back(m);
    }
}

} // namespace detail

// Every marker over the track, `phraseBeats` (a multiple of 4) apart. With
// `follow` and more than one section: each section's phrases on its own
// grid from its own phrase phase, and a re-anchor marker where each section
// after the first begins; else the master grid's.
inline std::vector<PhraseMarker> phraseMarkers(const PhraseGrid &grid, int phraseBeats, bool follow = false) {
    std::vector<PhraseMarker> out;
    const int barsPerPhrase = std::max(1, phraseBeats / 4);
    const double never = std::numeric_limits<double>::infinity();
    if (follow && grid.hasSections()) {
        for (size_t k = 0; k < grid.sections.size(); ++k) {
            const jl_grid_section &s = grid.sections[k];
            if (!(s.bpm > 0.0) || static_cast<size_t>(s.first_bar) + s.bar_count > grid.sectionBars.size()) continue;
            if (k > 0) {
                PhraseMarker start;
                start.phrase = -1;
                start.section = k;
                start.seconds = s.start_seconds;
                start.state = jl_phrase_reanchor;
                start.reanchorSeconds = s.start_seconds;
                start.bpm = s.bpm;
                out.push_back(start);
            }
            const double end = k + 1 < grid.sections.size() ? grid.sections[k + 1].start_seconds : never;
            detail::gridPhrases(out, grid.sectionBars.data() + s.first_bar, static_cast<long>(s.bar_count),
                                jl_section_beat_time(s, jl_section_first_bar_beat(s)), 4 * 60.0 / s.bpm,
                                firstPhraseBar(s.phrase_phase_bars, s.phrase_confidence, barsPerPhrase),
                                barsPerPhrase, end, k, s.bpm, nullptr);
        }
        return out;
    }
    const double bpm = grid.summary.bpm;
    if (!(bpm > 0.0) || grid.bars.empty()) return out;
    detail::gridPhrases(out, grid.bars.data(), static_cast<long>(grid.bars.size()),
                        jl_beat_time(grid.summary, jl_first_bar_beat(grid.summary)), 4 * 60.0 / bpm,
                        firstPhraseBar(grid.summary, barsPerPhrase), barsPerPhrase, never, 0, bpm, &grid.regions);
    return out;
}

// The grid that holds at `seconds`: its tempo and beat 0, for animation
// synced to the beat
struct GridAt {
    double bpm = 0.0;
    double anchorSeconds = 0.0;
};
inline GridAt gridAt(const PhraseGrid &grid, double seconds, bool follow) {
    GridAt out{ grid.summary.bpm, grid.summary.anchor_seconds };
    if (!follow || !grid.hasSections()) return out;
    for (const jl_grid_section &s : grid.sections) {
        if (s.start_seconds > seconds) break;
        if (s.bpm > 0.0) out = { s.bpm, s.anchor_seconds };
    }
    return out;
}

// Share of phrases that are Locked, for the summary badge (section starts
// are not phrases)
inline double lockedPhraseShare(const std::vector<PhraseMarker> &markers) {
    size_t locked = 0, phrases = 0;
    for (const PhraseMarker &m : markers) {
        if (m.phrase < 0) continue;
        phrases++;
        locked += m.state == jl_phrase_locked;
    }
    return phrases ? static_cast<double>(locked) / static_cast<double>(phrases) : 0.0;
}

} // namespace waveseek
