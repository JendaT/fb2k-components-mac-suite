//
//  BeatLoop.h
//  foo_wave_seekbar_mac
//
//  The mixer's audio side from the main thread: the "Beat loop" DSP
//  (BeatLoop.mm) runs LoopEngine first in the playback chain. Loops, jumps
//  and moves go to it as requests and play without a seek; one it turns
//  down (the audio is not buffered, or it has no track time) the view does
//  by seeking, armed so the seek gives it the track time again.
//
//  The playback position foobar2000 reports does not follow what the DSP
//  plays, so the view maps the audio played since the seek (the
//  visualisation clock) through the DSP's timeline instead.
//
//  Main thread only.
//

#pragma once

#include "../Core/LoopEngine.h"

#include <cstdint>
#include <vector>

namespace beatloop {

// An arm not taken by a seek within this long is dropped
constexpr double kArmTimeout = 2.0;

struct Status {
    uint64_t epoch = 0;         // counts the DSP's seeks
    bool synced = false;        // it knows the track time of what it plays
    bool pristine = true;       // nothing changed since the seek
    bool live = true;           // passing the audio through
    bool looping = false;
    unsigned rate = 0;
    double loopStart = 0.0, loopEnd = 0.0;
    double bufferedFrom = 0.0, bufferedTo = 0.0;   // the track audio it holds
    double outSeconds = 0.0;    // output since the seek
    double ahead = 0.0;         // decoded audio waiting, seconds
    uint64_t boundArmId = 0;    // the arm the last seek took
    uint64_t lastActionId = 0;
    uint64_t rejectedId = 0;
    std::vector<waveseek::LoopSegment> timeline;
};

// Adds the DSP first in the playback chain, or removes it (only when that
// changes the chain)
void setInChain(bool on);
// The DSP is part of the playback running now
bool running();

// A seek of the view's own to `target` is coming: it gives the DSP the
// track time, then `then` (optional) applies. Returns the arm's id.
uint64_t armSeek(double target, const waveseek::LoopAction *then);
// A request; returns its id. The status says when it was turned down.
uint64_t act(waveseek::LoopAction action);
// The view's measurement for the DSP's seek `epoch` (see LoopEngine::sync)
void sync(uint64_t epoch, double t0);
Status status();

// Seconds of audio played since the last seek; NAN when not known yet.
// Keeps a visualisation stream open until releaseClock().
double playedSinceSeek();
void releaseClock();

// While the user may change the loop: asks foobar2000 to keep its output
// latency low (foobar2000 2.25 and later), so a change is heard sooner
void setLowLatency(bool on);

} // namespace beatloop
