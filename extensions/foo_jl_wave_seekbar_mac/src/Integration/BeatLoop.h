//
//  BeatLoop.h
//  foo_wave_seekbar_mac
//
//  The mixer's gapless loop from the main thread: the "Beat loop" DSP
//  (BeatLoop.mm) runs LoopEngine first in the playback chain. Arm a loop,
//  then seek to its start: that seek binds it. Requests reach the DSP
//  between blocks; its status comes back after each block.
//
//  The playback position foobar2000 reports does not follow the loop's
//  passes, so the view maps the audio played since the seek (the
//  visualisation clock) through the loop's timeline instead.
//
//  Main thread only.
//

#pragma once

#include "../Core/LoopEngine.h"

#include <cstdint>
#include <vector>

namespace beatloop {

// An arm not bound by a seek within this long is dropped; the view then
// loops by seeking
constexpr double kArmTimeout = 2.0;

struct Status {
    uint64_t id = 0;            // the loop the last seek bound; 0 none
    bool flushedAway = false;   // dropped by a seek from elsewhere
    bool looping = false;       // still recording or repeating
    unsigned rate = 0;
    double start = 0.0;
    std::vector<waveseek::LoopSegment> timeline;
};

// Adds the DSP first in the playback chain, or removes it (only when that
// changes the chain)
void setInChain(bool on);
// The DSP is part of the playback running now
bool running();

// A new loop; returns its id. Seek to `start` right after.
uint64_t arm(double start, double length);
void setLength(uint64_t id, double length);
// Leave at the end of the pass playing, then play on
void exit(uint64_t id);
Status status();

// Seconds of audio played since the last seek; NAN when not known yet.
// Keeps a visualisation stream open until releaseClock().
double playedSinceSeek();
void releaseClock();

} // namespace beatloop
