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
    double startTime = 0.0;     // when synced: the track time of the first frame after the seek
    bool pristine = true;       // nothing changed since the seek
    bool live = true;           // passing the audio through
    bool looping = false;
    unsigned rate = 0;
    double loopStart = 0.0, loopEnd = 0.0;
    double bufferedFrom = 0.0, bufferedTo = 0.0;   // the track audio it holds
    double outSeconds = 0.0;    // output since the seek
    double ahead = 0.0;         // decoded audio waiting, seconds
    double blockSeconds = 0.0;  // how much audio foobar2000 hands the DSP at a time (recent average)
    double lastTakenMs = 0.0;   // how long the last request waited for the DSP to take it
    uint64_t lastTakenId = 0;
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

// The view sends its low latency, reserve and cap at every position check;
// what is older than this lapses, so a seekbar that went away or stopped
// its checks leaves nothing behind
constexpr double kFreshSeconds = 1.0;

// While the user may change the loop: asks foobar2000 to keep its output
// latency low (foobar2000 2.25 and later), and the DSP sends short steps
// (the decoder then runs ahead about as fast as it plays). Per seekbar
// (`owner`), on while any seekbar's is on and fresher than kFreshSeconds;
// off (also when a seekbar's lapses) lets go of foobar2000's hint once no
// seekbar wants it. A seekbar sends off when it stops its checks or goes.
void setLowLatency(const void *owner, bool on);

// While no change is expected (low latency off) the DSP keeps `seconds` of
// decoded audio ahead, so a forward jump within it plays without a seek; it
// reports them to foobar2000 as its latency. 0: it passes the audio through
// whenever it can. `aheadCap` bounds the decoded audio waiting, the
// reserve's and while hovering alike (INFINITY: no bound); towards a track's
// end it goes down to 0 so the change to the next track happens live. See
// LoopEngine::setReserveSeconds and setAheadCapSeconds.
// A pair older than kFreshSeconds lapses (no reserve, no cap).
void setReserve(double seconds, double aheadCap);

// foobar2000's output buffer is what delays every change. While the mixer
// is on it is set to `mixerMs` (0: left alone); the user's own is kept and
// put back when the mixer goes off (also at the next launch, if foobar2000
// quit in between). Changing it restarts playback once.
void applyMixerBuffer(bool mixerOn, int mixerMs);
// foobar2000's output buffer setting now, ms (0 when unknown)
int outputBufferMs();

// foobar2000 is quitting: lets go of its services while they still exist
// (one still held by a global at exit makes foobar2000 abort) and takes
// none again
void shutdown();

} // namespace beatloop
