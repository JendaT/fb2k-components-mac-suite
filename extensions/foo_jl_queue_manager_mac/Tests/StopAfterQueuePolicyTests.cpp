//
//  StopAfterQueuePolicyTests.cpp
//  foo_jl_queue_manager
//
//  Unit tests for StopAfterQueuePolicy ("Stop After Queue" decisions).
//  Pure C++, compiled standalone; run as a gating phase by Scripts/build.sh.
//

#include "../src/Core/StopAfterQueuePolicy.h"

#include <cstdio>

using namespace queue_stop;

static int g_failures = 0;
static int g_checks = 0;

static void check(bool condition, const char* name) {
    g_checks++;
    if (!condition) {
        g_failures++;
        printf("FAIL [%s]\n", name);
    }
}

static bool none(const Actions& a) {
    return !a.setStopAfterCurrent && !a.clearStopAfterCurrent && !a.disableSetting;
}

static const TrackId kA = 0x1000;
static const TrackId kB = 0x2000;

int main() {
    // Disabled: queue end does nothing
    {
        StopAfterQueuePolicy p;
        check(none(p.onQueueAdvancedToEmpty(false, kA)), "disabled: no action");
        check(!p.isArmed(), "disabled: not armed");
    }

    // Normal queue end: arm, then fb2k stops (flag already reset by fb2k)
    {
        StopAfterQueuePolicy p;
        Actions a = p.onQueueAdvancedToEmpty(true, kA);
        check(a.setStopAfterCurrent && !a.clearStopAfterCurrent && !a.disableSetting, "arm sets flag");
        check(p.isArmed() && p.armedTrack() == kA, "armed on consumed track");
        check(none(p.onNewTrack(kA, true)), "armed track starting is not a skip");
        check(none(p.onPlaybackStopped(StopReason::EndOfFile, false, false)), "stop, persistent mode");
        check(!p.isArmed(), "disarmed after stop");
    }

    // fb2k left the flag set after stopping: we clear it
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        Actions a = p.onPlaybackStopped(StopReason::EndOfFile, true, false);
        check(a.clearStopAfterCurrent && !a.disableSetting, "stale flag cleared on stop");
    }

    // Only-once mode turns the feature off at the queue end
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        Actions a = p.onPlaybackStopped(StopReason::EndOfFile, false, true);
        check(a.disableSetting && !a.clearStopAfterCurrent, "once: disabled after stop");
    }
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        Actions a = p.onPlaybackStopped(StopReason::User, true, true);
        check(a.disableSetting && a.clearStopAfterCurrent, "once: user stop during last track counts");
    }

    // Track changes and shutdown do not consume only-once
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        check(none(p.onPlaybackStopped(StopReason::StartingAnother, true, true)), "starting another ignored");
        check(p.isArmed(), "still armed after starting-another");
        check(none(p.onPlaybackStopped(StopReason::ShuttingDown, true, true)), "shutdown: no action");
        check(!p.isArmed(), "shutdown disarms");
    }

    // User queues more while the last queued track plays: cancel
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        Actions a = p.onQueueItemsAdded(kA, true);
        check(a.clearStopAfterCurrent && !a.disableSetting, "queue refilled: stop cancelled");
        check(!p.isArmed(), "queue refilled: disarmed");
        // The refilled queue can arm again at its end
        check(p.onQueueAdvancedToEmpty(true, kB).setStopAfterCurrent, "re-arm after refill");
    }

    // Items added but user already cleared the flag: do not touch it
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        check(none(p.onQueueItemsAdded(kA, false)), "flag cleared by user: untouched");
        check(!p.isArmed(), "flag cleared by user: disarmed");
    }

    // Items added after the armed track is no longer playing
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        check(none(p.onQueueItemsAdded(kB, true)), "other track playing: user's flag untouched");
        check(none(p.onQueueItemsAdded(0, true)), "not armed: no action");
    }

    // Turning the feature off while armed cancels the pending stop
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        Actions a = p.onSettingDisabled(kA, true);
        check(a.clearStopAfterCurrent && !a.disableSetting, "disable: pending stop cancelled");
        check(none(p.onPlaybackStopped(StopReason::EndOfFile, false, true)), "disable: later stop ignored");
    }
    {
        StopAfterQueuePolicy p;
        check(none(p.onSettingDisabled(kA, true)), "disable while not armed: user's flag untouched");
    }

    // User skips past the last queued track: withdraw the stop
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        Actions a = p.onNewTrack(kB, true);
        check(a.clearStopAfterCurrent, "skip: stop withdrawn");
        check(!p.isArmed(), "skip: disarmed");
        check(none(p.onPlaybackStopped(StopReason::User, false, true)), "skip: later stop does not consume once");
    }
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, kA);
        Actions a = p.onNewTrack(kB, false);
        check(none(a) && !p.isArmed(), "skip with flag already clear: disarm only");
    }

    // Unknown armed identity: never treat a new track as a skip
    {
        StopAfterQueuePolicy p;
        p.onQueueAdvancedToEmpty(true, 0);
        check(none(p.onNewTrack(kB, true)) && p.isArmed(), "unknown identity: new track ignored");
        check(none(p.onQueueItemsAdded(kB, true)), "unknown identity: refill cannot verify, flag untouched");
    }

    if (g_failures > 0) {
        printf("StopAfterQueuePolicyTests: %d of %d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    printf("StopAfterQueuePolicyTests: all %d checks passed\n", g_checks);
    return 0;
}
