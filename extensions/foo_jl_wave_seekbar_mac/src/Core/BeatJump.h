//
//  BeatJump.h
//  foo_wave_seekbar_mac
//
//  Beat jumps, beat loops and seeking to a beat, on the track's beat grid:
//  every beat's time (the master grid's, or section by section when
//  following a new grid), jumps that keep the position's place within its
//  beat, the beat nearest a click, loops from the beat behind the cursor,
//  and what a playing loop asks of playback at each position check.
//  Header-only, tested standalone; the view keeps the state and seeks.
//

#pragma once

#include "PhraseMarkers.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <vector>

namespace waveseek {

// Sizes offered in the size menu: the length of a loop and of the jumps
// beside the menu
constexpr int kBeatSizeChoices[] = { 1, 2, 4, 8, 16, 32 };
constexpr int kDefaultBeatSize = 4;

// Nothing is placed closer than this to the track's end: seeking there
// skips to the next track
constexpr double kBeatEndMargin = 0.25;
// A beat this little ahead of the cursor counts as behind it: the loop was
// asked for on the beat, a hair early
constexpr double kLoopSnapAhead = 0.03;
// Playback this far outside a loop was moved there by something else (a
// seek from another control): the loop ends
constexpr double kLoopSlack = 0.5;

// Every beat from 0 to `duration`, ascending: the master grid's, or with
// `follow` and sections each section's own grid, from its first beat up to
// the next section's first beat. An earlier grid's beat closer than half
// its beat to the next grid's first beat is left out.
inline std::vector<double> beatTimes(const PhraseGrid &grid, double duration, bool follow) {
    std::vector<double> out;
    if (!(duration > 0.0)) return out;
    auto addGrid = [&](double anchor, double bpm, double from, double to) {
        if (!(bpm >= 1.0) || !(bpm <= 1000.0) || !(to > from) || !std::isfinite(anchor)) return;
        const double period = 60.0 / bpm;
        for (double j = std::ceil((from - anchor) / period - 1e-9);; j += 1.0) {
            const double t = anchor + j * period;
            if (t >= to) break;
            if (t >= from - 1e-9) out.push_back(std::max(0.0, t));
        }
    };
    const double end = duration + 1e-9;
    if (follow && grid.hasSections()) {
        const std::vector<jl_grid_section> &sections = grid.sections;
        // Where each section's beats begin: the track's start, else its first beat
        std::vector<double> begin(sections.size(), 0.0);
        for (size_t k = 1; k < sections.size(); ++k) {
            begin[k] = std::max(begin[k - 1], std::min(sections[k].start_seconds, sections[k].anchor_seconds));
        }
        for (size_t k = 0; k < sections.size(); ++k) {
            const jl_grid_section &s = sections[k];
            if (!(s.bpm > 0.0)) continue;
            const double to = k + 1 < sections.size() ? std::min(end, begin[k + 1] - 0.5 * 60.0 / s.bpm) : end;
            addGrid(s.anchor_seconds, s.bpm, begin[k], to);
        }
    } else {
        addGrid(grid.summary.anchor_seconds, grid.summary.bpm, 0.0, end);
    }
    return out;
}

// `seconds` as a beat number: i at beats[i], fractional between beats;
// before the first beat and after the last the nearest interval carries
// on. NAN with fewer than two beats.
inline double beatPosition(const std::vector<double> &beats, double seconds) {
    const size_t n = beats.size();
    if (n < 2 || !std::isfinite(seconds)) return NAN;
    const size_t above = static_cast<size_t>(std::upper_bound(beats.begin(), beats.end(), seconds) - beats.begin());
    const size_t lo = above == 0 ? 0 : std::min(above - 1, n - 2);
    return static_cast<double>(lo) + (seconds - beats[lo]) / (beats[lo + 1] - beats[lo]);
}

// The time of beat number `position` (beatPosition's inverse)
inline double timeAtBeat(const std::vector<double> &beats, double position) {
    const size_t n = beats.size();
    if (n < 2 || !std::isfinite(position)) return NAN;
    const double floor = std::floor(position);
    const size_t lo = floor <= 0.0 ? 0 : std::min(static_cast<size_t>(floor), n - 2);
    return beats[lo] + (position - static_cast<double>(lo)) * (beats[lo + 1] - beats[lo]);
}

// The beat nearest `seconds`; NAN without beats
inline double nearestBeat(const std::vector<double> &beats, double seconds) {
    if (beats.empty() || !std::isfinite(seconds)) return NAN;
    const auto above = std::lower_bound(beats.begin(), beats.end(), seconds);
    if (above == beats.begin()) return beats.front();
    if (above == beats.end()) return beats.back();
    return seconds - *(above - 1) <= *above - seconds ? *(above - 1) : *above;
}

// `seconds` moved by `count` beats, at the same place within its beat.
// Back past the start stops at 0; NAN when it would land too near the end
// (or there is no grid).
inline double jumpTarget(const std::vector<double> &beats, double seconds, int count, double duration) {
    const double t = timeAtBeat(beats, beatPosition(beats, seconds) + count);
    if (std::isnan(t) || t > duration - kBeatEndMargin) return NAN;
    return std::max(0.0, t);
}

// A loop over whole beats
struct BeatLoop {
    double start = 0.0;
    double end = 0.0;
    long firstBeat = 0;         // index into the beats
    int beats = 0;              // its length; 0 = no loop

    bool active() const { return beats > 0 && end > start; }
    double length() const { return end - start; }
    bool contains(double seconds) const { return active() && seconds >= start && seconds < end; }
};

// `length` beats from beat `first`; no loop when that starts before the
// track or ends too near its end
inline BeatLoop loopFromBeat(const std::vector<double> &beats, long first, int length, double duration) {
    BeatLoop loop;
    if (beats.size() < 2 || length <= 0 || first < 0) return loop;
    const double start = timeAtBeat(beats, static_cast<double>(first));
    const double end = timeAtBeat(beats, static_cast<double>(first + length));
    if (std::isnan(start) || std::isnan(end) || start < 0.0 || end > duration - kBeatEndMargin || !(end > start)) {
        return loop;
    }
    loop.start = start;
    loop.end = end;
    loop.firstBeat = first;
    loop.beats = length;
    return loop;
}

// How far from a phrase start a loop's start is caught by it, in beats:
// a loop asked for up to this many beats after the phrase start (late) ...
inline int phraseCatchBehind(int length) { return length >= 16 ? 4 : length >= 8 ? 2 : 1; }
// ... or up to a beat before it (early)
constexpr int kPhraseCatchAhead = 1;

// `length` beats from the beat at or behind `seconds` (one kLoopSnapAhead
// ahead counts as behind; before the first beat, from the first). Near a
// phrase start (`phraseStarts`, seconds, the 16-beat marks) the loop starts
// there instead: a beat or two late, or one early, the intention was the
// phrase, the more so the longer the loop.
inline BeatLoop makeLoop(const std::vector<double> &beats, double seconds, int length, double duration,
                         const std::vector<double> &phraseStarts = {}) {
    if (beats.size() < 2 || !std::isfinite(seconds)) return {};
    const auto above = std::upper_bound(beats.begin(), beats.end(), seconds + kLoopSnapAhead);
    long first = above == beats.begin() ? 0 : static_cast<long>(above - beats.begin()) - 1;
    long best = first;
    long bestDistance = std::numeric_limits<long>::max();
    for (double p : phraseStarts) {
        const long phrase = static_cast<long>(std::lround(beatPosition(beats, p)));
        const long d = phrase - first;   // positive: the phrase starts after the beat behind the cursor
        if (d < -phraseCatchBehind(length) || d > kPhraseCatchAhead || phrase < 0) continue;
        if (std::labs(d) < bestDistance) {
            bestDistance = std::labs(d);
            best = phrase;
        }
    }
    first = best;
    return loopFromBeat(beats, first, length, duration);
}

// The same start, `length` beats long
inline BeatLoop resizedLoop(const std::vector<double> &beats, const BeatLoop &loop, int length, double duration) {
    return loop.active() ? loopFromBeat(beats, loop.firstBeat, length, duration) : BeatLoop{};
}

// The loop moved by `count` beats; no loop when that leaves the track
inline BeatLoop movedLoop(const std::vector<double> &beats, const BeatLoop &loop, int count, double duration) {
    return loop.active() ? loopFromBeat(beats, loop.firstBeat + count, loop.beats, duration) : BeatLoop{};
}

// Where `seconds` lands with the loop repeating: its distance from the
// loop's start, modulo the length
inline double wrappedIntoLoop(const BeatLoop &loop, double seconds) {
    if (!loop.active()) return seconds;
    const double into = std::fmod(seconds - loop.start, loop.length());
    return loop.start + (into < 0.0 ? into + loop.length() : into);
}

// What a playing loop asks for at playback position `seconds`, checked
// again in about `lookahead` seconds
struct LoopStep {
    enum Kind { None, Seek, Schedule, Leave };
    Kind kind = None;
    double value = 0.0;         // Seek: where to; Schedule: how long until the end
};

inline LoopStep loopStep(const BeatLoop &loop, double seconds, double lookahead) {
    if (!loop.active() || !std::isfinite(seconds)) return {};
    if (seconds < loop.start - kLoopSlack || seconds > loop.end + kLoopSlack) return { LoopStep::Leave, 0.0 };
    // Late: back to the start, as far in as it overran, so the beat holds
    if (seconds >= loop.end) return { LoopStep::Seek, loop.start + std::fmod(seconds - loop.end, loop.length()) };
    if (loop.end - seconds <= lookahead) return { LoopStep::Schedule, loop.end - seconds };
    return {};
}

} // namespace waveseek
