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

    // --- Normal play: now-playing at 3s, scrobble at 50%, start timestamp ---
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

        d = play(t, 4, 99);
        CHECK(!d.scrobble, "not yet at 50% (99s < 100s)");
        d = t.onTime(100.0);
        CHECK(d.scrobble, "scrobbles at 50%");
        CHECK(d.timestamp == kStart, "stamped with track START time");
        CHECK(t.scrobbled(), "state records scrobble");

        d = play(t, 100, 200);
        CHECK(!d.scrobble, "never scrobbles twice while playing");
    }

    // --- Long track: 4-minute cap instead of 50% ---
    {
        g_context = "four-minute-cap";
        PlaybackTracker t;
        t.beginTrack(true, 1200.0, true, kStart);  // 20 min track
        PlaybackDecision d = play(t, 0, 239);
        CHECK(!d.scrobble, "not at 239s");
        d = t.onTime(240.0);
        CHECK(d.scrobble, "scrobbles at 240s cap");
    }

    // --- Stop after qualifying: no double scrobble ---
    {
        g_context = "stop-after-scrobble";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        PlaybackDecision d = play(t, 0, 60);
        CHECK(d.scrobble, "scrobbled mid-play");
        d = t.onStop(false);
        CHECK(!d.scrobble, "stop must not queue the track again");
        CHECK(!t.hasTrack(), "tracking ends on stop");
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

    // --- Stop finalizes a qualified-but-unscrobbled track ---
    // (mid-play scrobble was suppressed while metadata was invalid)
    {
        g_context = "stop-finalizes";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        t.onTrackEdited(100.0, false);
        play(t, 0, 80);
        CHECK(!t.scrobbled(), "suppressed while invalid");
        t.onTrackEdited(100.0, true);
        PlaybackDecision d = t.onStop(false);
        CHECK(d.scrobble, "stop finalizes the earned scrobble");
        CHECK(d.timestamp == kStart, "with the track's start time");
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

    // --- Track-switch: previous qualified-but-unscrobbled track finalizes ---
    // (can happen when stop lands between qualification and the next tick;
    //  reproduce by disabling mid-play scrobble via a validity flip)
    {
        g_context = "switch-finalizes";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        t.onTrackEdited(100.0, false);      // invalid: mid-play scrobble suppressed
        play(t, 0, 80);
        CHECK(!t.scrobbled(), "invalid track did not scrobble mid-play");
        t.onTrackEdited(100.0, true);       // metadata fixed
        PlaybackDecision d = t.beginTrack(true, 180.0, true, kStart + 81);
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
        CHECK(!d.scrobble, "position 151s but only 11s listened");
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
        CHECK(t.scrobbled(), "80s of real listening across seeks qualifies");
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
        g_context = "pause";
        PlaybackTracker t;
        t.beginTrack(true, 100.0, true, kStart);
        play(t, 0, 10);
        // (pause: no onTime calls) ... resume produces a tick with delta 0-1s
        PlaybackDecision d = t.onTime(11.0);
        CHECK(!d.scrobble, "resume tick is normal progression");
        CHECK(t.accumulatedTime() > 10.9 && t.accumulatedTime() < 11.1,
              "accumulation continues seamlessly after pause");
    }

    printf("PlaybackTrackerTests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
