//
//  PhraseMarkers.h
//  foo_wave_seekbar_mac
//
//  Phrase markers from a beat grid served by BPM Analyzer (jl_beatgrid):
//  where each 16- or 32-beat phrase starts, its state by the shared rule
//  (jl_classify_phrase), and how far to thin them so markers stay apart.
//  On the master grid, or following the grid where it changes: section by
//  section, each counting its own phrases on its own tempo. Also the
//  trusted grid for beats, jumps and loops: sections that don't fit their
//  own bars give way to the master grid.
//  Header-only, tested standalone; the view only draws what this returns.
//

#pragma once

#include "../../../../shared/jl_beatgrid_types.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
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
                        uint8_t source, const std::vector<jl_beat_region> *regions) {
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
        m.state = jl_classify_phrase(bars + start, static_cast<size_t>(n), source);

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
                                barsPerPhrase, end, k, s.bpm, grid.summary.source, nullptr);
        }
        return out;
    }
    const double bpm = grid.summary.bpm;
    if (!(bpm > 0.0) || grid.bars.empty()) return out;
    detail::gridPhrases(out, grid.bars.data(), static_cast<long>(grid.bars.size()),
                        jl_beat_time(grid.summary, jl_first_bar_beat(grid.summary)), 4 * 60.0 / bpm,
                        firstPhraseBar(grid.summary, barsPerPhrase), barsPerPhrase, never, 0, bpm, grid.summary.source,
                        &grid.regions);
    return out;
}

// The grid that holds at `seconds`: its tempo and beat 0, for animation
// synced to the beat and jumps in phase. Following the sections, a section
// holds from its start or its first beat, whichever comes first (its beat 0
// can sit up to 25 ms before its start), as in the beat list (beatTimes).
struct GridAt {
    double bpm = 0.0;
    double anchorSeconds = 0.0;
};
inline GridAt gridAt(const PhraseGrid &grid, double seconds, bool follow) {
    GridAt out{ grid.summary.bpm, grid.summary.anchor_seconds };
    if (!follow || !grid.hasSections()) return out;
    double begin = 0.0;
    for (size_t k = 0; k < grid.sections.size(); ++k) {
        const jl_grid_section &s = grid.sections[k];
        if (k > 0) begin = std::max(begin, std::min(s.start_seconds, s.anchor_seconds));
        if (begin > seconds) break;
        if (s.bpm > 0.0) out = { s.bpm, s.anchor_seconds };
    }
    return out;
}

// ---------------------------------------------------------------------------
// Trusted sections
// ---------------------------------------------------------------------------

// A section's grid judged by its own bars: only the bars with a beat (the
// pulse level jl_classify_phrase counts) that is not off-beat say anything.
// Such a bar is good within kSectionFitMs of its grid beats with 3 in 4 of
// the beats it heard matched; the section fits with at least
// kSectionFitMinGood good bars, half or more of those judged.
constexpr int kSectionFitMs = 15;
constexpr size_t kSectionFitMinGood = 8;

struct SectionFit {
    size_t judged = 0;          // bars with a beat on them
    size_t good = 0;            // of those, on the section's grid
    bool fits() const { return good >= kSectionFitMinGood && good * 2 >= judged; }
};

// Section `k`'s bars against its grid; nothing judged when it has no tempo
// or its bars are missing
inline SectionFit sectionFit(const PhraseGrid &grid, size_t k) {
    SectionFit fit;
    if (k >= grid.sections.size()) return fit;
    const jl_grid_section &s = grid.sections[k];
    if (!(s.bpm > 0.0) || static_cast<size_t>(s.first_bar) + s.bar_count > grid.sectionBars.size()) return fit;
    for (uint32_t i = 0; i < s.bar_count; ++i) {
        const jl_bar_stat &b = grid.sectionBars[s.first_bar + i];
        if (b.pulse < jl_phrase_no_pulse_level * jl_pulse_unit || (b.flags & jl_bar_offbeat)) continue;
        fit.judged++;
        if (std::abs(static_cast<int>(b.offset_ms)) <= kSectionFitMs &&
            static_cast<size_t>(b.matched) * 4 >= 3 * jl_bar_heard_beats(b, grid.summary.source)) {
            fit.good++;
        }
    }
    return fit;
}

inline bool sectionFits(const PhraseGrid &grid, size_t k) { return sectionFit(grid, k).fits(); }

// A section whose every beat is this close to one of the master grid's is
// on the master's beats
constexpr double kSameBeatSeconds = 0.001;

namespace detail {

// The master's beat nearest `seconds`, by number
inline long masterBeatNear(const jl_beatgrid_summary &m, double seconds) {
    return std::lround((seconds - m.anchor_seconds) * m.bpm / 60.0);
}

// Whether section `s` places its beats on the master's, from its beat 0 to
// the end of its last bar: within kSameBeatSeconds and none gained or lost
inline bool onMasterBeats(const jl_beatgrid_summary &m, const jl_grid_section &s) {
    const double period = 60.0 / m.bpm;
    const long last = jl_section_first_bar_beat(s) + 4 * static_cast<long>(s.bar_count);
    const double from = s.anchor_seconds, to = jl_section_beat_time(s, last);
    const long a = masterBeatNear(m, from), b = masterBeatNear(m, to);
    return b - a == last && std::fabs(from - (m.anchor_seconds + a * period)) <= kSameBeatSeconds &&
           std::fabs(to - (m.anchor_seconds + b * period)) <= kSameBeatSeconds;
}

// The master grid as a section from its beat nearest `from` (the track's
// start for the first section) up to `to`: its bar and phrase count carry
// on, and its bars are the master's bars starting before `to`, appended to
// `bars`
inline jl_grid_section masterSpan(const PhraseGrid &grid, bool first, double from, double to,
                                  std::vector<jl_bar_stat> &bars) {
    const jl_beatgrid_summary &m = grid.summary;
    const double period = 60.0 / m.bpm;
    const long barBeat = jl_first_bar_beat(m);
    const long beat0 = first ? 0 : std::max(0L, masterBeatNear(m, from));
    const long phase = ((barBeat - beat0) % 4 + 4) % 4;
    const long firstBar = (beat0 + phase - barBeat) / 4;   // the master's bar its bar 0 is
    const long have = static_cast<long>(grid.bars.size());
    long endBar = have;
    if (std::isfinite(to)) {
        endBar = static_cast<long>(std::ceil(((to - m.anchor_seconds) / period - static_cast<double>(barBeat)) / 4.0 - 1e-9));
    }
    endBar = std::min(endBar, have);
    const long count = std::max(0L, endBar - firstBar);

    jl_grid_section s{};
    s.anchor_seconds = m.anchor_seconds + static_cast<double>(beat0) * period;
    s.start_seconds = first ? 0.0 : s.anchor_seconds;
    s.bpm = m.bpm;
    s.bar_phase = static_cast<int8_t>(phase);
    s.phrase_phase_bars = m.phrase_phase_bars >= 0
        ? static_cast<int8_t>(((m.phrase_phase_bars - firstBar) % 8 + 8) % 8) : m.phrase_phase_bars;
    s.phrase_confidence = m.phrase_confidence;
    s.first_bar = static_cast<uint32_t>(bars.size());
    s.bar_count = static_cast<uint32_t>(count);
    if (count > 0) bars.insert(bars.end(), grid.bars.begin() + firstBar, grid.bars.begin() + firstBar + count);
    return s;
}

} // namespace detail

// The grid to place beats, jumps and loops on (beatTimes, gridAt,
// phraseMarkers read it as any grid). Every section that doesn't fit its
// own bars (sectionFits) gives way to the master grid over its span,
// neighbouring ones merged into one master section that starts on the
// master's beat nearest the first one's start; a fitting section on the
// master's beats (onMasterBeats) takes the master's exact tempo and beat,
// keeping its own bars and phrase count. So where the master grid holds,
// the beats are the master's without a join. A track on one grid, or
// without a master tempo, comes back as it is.
inline PhraseGrid trustedGrid(const PhraseGrid &grid) {
    const jl_beatgrid_summary &m = grid.summary;
    if (!grid.hasSections() || !(m.bpm >= 1.0) || !(m.bpm <= 1000.0) || !std::isfinite(m.anchor_seconds)) return grid;
    PhraseGrid out = grid;
    out.sections.clear();
    out.sectionBars.clear();
    const size_t n = grid.sections.size();
    for (size_t k = 0; k < n;) {
        const jl_grid_section &s = grid.sections[k];
        if (sectionFits(grid, k)) {
            jl_grid_section kept = s;
            kept.first_bar = static_cast<uint32_t>(out.sectionBars.size());
            out.sectionBars.insert(out.sectionBars.end(), grid.sectionBars.begin() + s.first_bar,
                                   grid.sectionBars.begin() + s.first_bar + s.bar_count);
            if (detail::onMasterBeats(m, s)) {
                kept.bpm = m.bpm;
                kept.anchor_seconds = m.anchor_seconds +
                                      static_cast<double>(detail::masterBeatNear(m, s.anchor_seconds)) * 60.0 / m.bpm;
            }
            out.sections.push_back(kept);
            ++k;
            continue;
        }
        size_t next = k + 1;
        while (next < n && !sectionFits(grid, next)) ++next;
        const double to = next < n ? grid.sections[next].start_seconds : std::numeric_limits<double>::infinity();
        out.sections.push_back(detail::masterSpan(grid, k == 0, s.start_seconds, to, out.sectionBars));
        k = next;
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
