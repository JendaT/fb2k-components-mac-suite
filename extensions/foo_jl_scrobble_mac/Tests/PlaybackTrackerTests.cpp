//
//  PlaybackTrackerTests.cpp
//  foo_jl_scrobble_mac
//
//  Unit tests for the PlaybackTracker playback-to-scrobble state machine.
//  Compiled standalone (pure C++); gating phase of Scripts/build.sh.
//

#include "../src/Core/PlaybackTracker.h"

#include <cstdio>
#include <string>

static int g_failures = 0;
static int g_checks = 0;
static std::string g_context;

#define CHECK(cond, what)                                                        \
    do {                                                                         \
        g_checks++;                                                             \
        if (!(cond)) {                                                          \
            g_failures++;                                                       \
            printf("FAIL [%s] %s\n", g_context.c_str(), what);                  \
        }                                                                       \
    } while (0)

using scrobble::PlaybackTracker;
using scrobble::PlaybackDecision;

// Feed 1-second ticks from `from` (exclusive) to `to` (inclusive), returning
// the OR of decisions and asserting scrobble fires at most once.
static PlaybackDecision play(PlaybackTracker &t, int from, int to) {
    PlaybackDecision merged;
    for (int s = from + 1; s <= to; s++) {
        PlaybackDecision d = t.onTime((double)s);
        if (d.sendNowPlaying) merged.sendNowPlaying = true;
        if (d.scrobble) {
            CHECK(!merged.scrobble, "scrobble decision fired twice within play()");
            merged.scrobble = true;
            merged.timestamp = d.timestamp;
        }
    }
    return merged;
}

int main(void) {
    const int64_t kStart = 1751000000;

    // --- Normal play: now-playing at 3s, scrobble deferred to the boundary ---
    {
        g_context = "normal-play";
        PlaybackTracker t;
        PlaybackDecision d = t.beginTrack(true, 200.0, true, kStart);
        CHECK(!d.scrobble, "nothing to finalize on first track");

        d = t.onTime(1.0);
        CHECK(!d.sendNowPlaying, "no now-playing at 1s");
        d = t.onTime(2.0);
        CHECK(!d.sendNowPlaying, "no now-playing at 2s");
        d = t.onTime(3.0);
        CHECK(d.sendNowPlaying, "now-playing at 3s");
        d = t.onTime(4.0);
        CHECK(!d.sendNowPlaying, "now-playing sent only once");

        d = play(t, 4, 200);
        CHECK(!d.scrobble, "never scrobbles mid-playback, even well past 50%");
        CHECK(!t.scrobbled(), "nothing submitted while the track is still playing");

        d = t.onStop(false);
        CHECK(d.scrobble, "the earned scrobble lands at the stop boundary");
        CHECK(d.timestamp == kStart, "stamped with track START time");
        CHECK(t.scrobbled(), "state records scrobble");
    }

    // --- Eligibility threshold: 50% of duration, measured at the boundary ---
    {
        g_context = "fifty-percent-threshold";
        PlaybackTracker below;
        below.beginTrack(true, 200.0, true, kStart);
        play(below, 0, 99);
        CHECK(!below.onStop(false).scrobble, "99s of a 200s track does not qualify");

        PlaybackTracker at;
        at.beginTrack(true, 200.0, true, kStart);
        play(at, 0, 100);
        CHECK(at.onStop(false).scrobble, "100s of a 200s track qualifies");
    }

    // --- Long track: 4-minute cap instead of 50% ---
    {
        g_context = "four-minute-cap";
        PlaybackTracker below;
        below.beginTrack(true, 1200.0, true, kStart);  // 20 min track
        play(below, 0, 239);
        CHECK(!below.onStop(false).scrobble, "not at 239s");

        PlaybackTracker at;
        at.beginTrack(true, 1200.0, true, kStart);
        play(at, 0, 240);
        CHECK(at.onStop(false).scrobble, "qualifies at the 240s cap");
    }

    // --- Stop after qualifying: submitted exactly once, tracking ends ---
    {
        g_context = "stop-after-qualifying";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        PlaybackDecision d = play(t, 0, 60);
        CHECK(!d.scrobble, "nothing submitted while playing");
        d = t.onStop(false);
        CHECK(d.scrobble, "stop submits it");
        CHECK(!t.hasTrack(), "tracking ends on stop");
        d = t.onStop(false);
        CHECK(!d.scrobble, "a second stop must not queue the track again");
    }

    // --- Pause is a boundary: eligible track is submitted, exactly once ---
    {
        g_context = "pause-finalizes";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        play(t, 0, 60);
        PlaybackDecision d = t.onPause(true);
        CHECK(d.scrobble, "pause submits the earned scrobble");
        CHECK(d.timestamp == kStart, "with the track's start time");

        d = t.onPause(false);
        CHECK(!d.scrobble, "resume submits nothing");
        d = play(t, 60, 100);
        CHECK(!d.scrobble, "and nothing more accumulates into a second scrobble");
        d = t.onStop(false);
        CHECK(!d.scrobble, "stop must not queue the track a second time");
    }

    // --- Pause before qualifying: nothing submitted, tracking continues ---
    {
        g_context = "pause-early";
        PlaybackTracker t;
        t.beginTrack(true, 200.0, true, kStart);
        play(t, 0, 30);
        PlaybackDecision d = t.onPause(true);
        CHECK(!d.scrobble, "30s of a 200s track does not scrobble on pause");
        d = t.onPause(false);
        CHECK(!d.scrobble, "nor on resume");

        play(t, 30, 100);
        d = t.onStop(false);
        CHECK(d.scrobble, "listening resumed and still earned the scrobble");
        CHECK(d.timestamp == kStart, "stamped with the original start time");
    }

    // --- Stop before qualifying threshold: no scrobble ---
    {
        g_context = "stop-early";
        PlaybackTracker t;
        t.beginTrack(true, 200.0, true, kStart);
        play(t, 0, 30);
        PlaybackDecision d = t.onStop(false);
        CHECK(!d.scrobble, "30s of a 200s track does not scrobble");
    }

    // --- Validity is judged at the boundary, not while playing ---
    {
        g_context = "stop-finalizes";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        t.onTrackEdited(100.0, false);      // metadata went invalid mid-play
        play(t, 0, 80);
        CHECK(!t.scrobbled(), "nothing submitted while playing");
        t.onTrackEdited(100.0, true);       // metadata fixed before the boundary
        PlaybackDecision d = t.onStop(false);
        CHECK(d.scrobble, "stop finalizes the earned scrobble");
        CHECK(d.timestamp == kStart, "with the track's start time");
    }

    // --- Still invalid at the boundary: dropped ---
    {
        g_context = "stop-invalid";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        t.onTrackEdited(100.0, false);
        play(t, 0, 80);
        PlaybackDecision d = t.onStop(false);
        CHECK(!d.scrobble, "invalid metadata is not scrobbled at the boundary");
    }

    // --- Track-switch: previous unqualified track is dropped ---
    {
        g_context = "switch-early";
        PlaybackTracker t;
        t.beginTrack(true, 200.0, true, kStart);
        play(t, 0, 30);
        PlaybackDecision d = t.onStop(true);   // stop_reason_starting_another
        CHECK(!d.scrobble, "starting-another stop does nothing");
        CHECK(t.hasTrack(), "track kept for beginTrack to finalize");
        d = t.beginTrack(true, 180.0, true, kStart + 31);
        CHECK(!d.scrobble, "previous track had not earned a scrobble");
    }

    // --- Track-switch: previous qualified track finalizes at the new track ---
    // (the real fb2k sequence: stop(starting_another) then new_track)
    {
        g_context = "switch-finalizes";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        play(t, 0, 80);
        CHECK(!t.scrobbled(), "not submitted while the track was playing");

        PlaybackDecision d = t.onStop(true);
        CHECK(!d.scrobble, "starting-another stop defers to beginTrack");
        d = t.beginTrack(true, 180.0, true, kStart + 81);
        CHECK(d.scrobble, "previous track finalized on switch");
        CHECK(d.timestamp == kStart, "finalized with PREVIOUS track's start time");
    }

    // --- Seek handling: jumps do not count as listening ---
    {
        g_context = "seek";
        PlaybackTracker t;
        t.beginTrack(true, 200.0, true, kStart);
        play(t, 0, 10);                     // 10s listened
        t.onSeek(150.0);                    // jump forward
        PlaybackDecision d = t.onTime(151.0);
        CHECK(t.accumulatedTime() > 10.9 && t.accumulatedTime() < 11.1,
              "seek preserved accumulated time and resynced position");

        // Jump without on_playback_seek (delta >= 2s in on_time) also ignored
        d = t.onTime(190.0);
        CHECK(t.accumulatedTime() < 12.0, "large delta not accumulated");
        // Backward jump ignored too
        d = t.onTime(5.0);
        CHECK(t.accumulatedTime() < 12.0, "negative delta not accumulated");
        d = t.onTime(6.0);
        CHECK(t.accumulatedTime() > 11.9 && t.accumulatedTime() < 12.1,
              "normal progression resumes after backward jump");
    }

    // --- Seek-heavy track never reaches threshold by position alone ---
    {
        g_context = "seek-no-cheat";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        // Repeatedly seek near the end and play 1s: position is high,
        // accumulated listening stays low.
        for (int i = 0; i < 40; i++) {
            t.onSeek(90.0);
            t.onTime(91.0);
            t.onSeek(0.0);
            t.onTime(1.0);
        }
        CHECK(t.onStop(false).scrobble, "80s of real listening across seeks qualifies");
        // (40 * 2s = 80s accumulated >= 50s required; seeks themselves added 0)
    }

    // --- Short / invalid / missing tracks ---
    {
        g_context = "ineligible-tracks";
        PlaybackTracker t;
        t.beginTrack(true, 20.0, true, kStart);   // under 30s
        PlaybackDecision d = play(t, 0, 20);
        CHECK(d.sendNowPlaying, "short track still gets now-playing");
        CHECK(!d.scrobble, "under-30s track never scrobbles");
        d = t.onStop(false);
        CHECK(!d.scrobble, "not on stop either");

        t.beginTrack(false, 0.0, false, kStart);  // extraction failed
        d = play(t, 0, 300);
        CHECK(!d.sendNowPlaying && !d.scrobble, "no events without a track");
        CHECK(t.accumulatedTime() == 0.0, "no accumulation without a track");
    }

    // --- Paused playback: no ticks arrive, nothing accumulates ---
    {
        g_context = "pause-accumulation";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        play(t, 0, 10);
        t.onPause(true);
        // (paused: no onTime calls at all)
        CHECK(t.accumulatedTime() > 9.9 && t.accumulatedTime() < 10.1,
              "a pause of any length accumulates nothing");
        t.onPause(false);
        // resume produces a tick with delta 0-1s
        t.onTime(11.0);
        CHECK(t.accumulatedTime() > 10.9 && t.accumulatedTime() < 11.1,
              "accumulation continues seamlessly after pause");
    }

    printf("PlaybackTrackerTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
