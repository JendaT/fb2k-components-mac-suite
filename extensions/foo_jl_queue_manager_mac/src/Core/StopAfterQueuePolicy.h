//
//  StopAfterQueuePolicy.h
//  foo_jl_queue_manager
//
//  Decision logic for "Stop After Queue": when playback consumes the last
//  queued track, arm fb2k's "stop after current" so playback ends with
//  that track. Pure C++ (no SDK) so it compiles and tests standalone; the
//  integration layer feeds it events and applies the returned actions.
//

#pragma once

#include <cstdint>

namespace queue_stop {

// Opaque track identity (the integration layer passes metadb_handle
// pointers it keeps alive). 0 = no track.
typedef uintptr_t TrackId;

enum class StopReason {
    User,
    EndOfFile,
    StartingAnother,
    ShuttingDown,
};

// What the integration layer must do after an event
struct Actions {
    bool setStopAfterCurrent = false;    // arm fb2k's stop-after-current
    bool clearStopAfterCurrent = false;  // undo our earlier arming
    bool disableSetting = false;         // "only once" mode: turn feature off
};

class StopAfterQueuePolicy {
public:
    // Playback advanced into the last queued track (queue now empty).
    // `consumed` is that track.
    Actions onQueueAdvancedToEmpty(bool enabled, TrackId consumed);

    // The user added items to the queue. If our armed track is still
    // playing with stop-after-current set, the queue did not really end.
    Actions onQueueItemsAdded(TrackId nowPlaying, bool stopAfterCurrentSet);

    // The user turned the feature off: cancel a pending stop we armed.
    Actions onSettingDisabled(TrackId nowPlaying, bool stopAfterCurrentSet);

    // A new track started. A track other than the armed one means the
    // user moved on, so the pending stop no longer belongs to the queue.
    Actions onNewTrack(TrackId track, bool stopAfterCurrentSet);

    // Playback stopped. For an armed stop this is the queue end: in
    // "only once" mode the feature turns itself off.
    Actions onPlaybackStopped(StopReason reason, bool stopAfterCurrentSet, bool onlyOnce);

    bool isArmed() const { return m_armed; }
    TrackId armedTrack() const { return m_armedTrack; }

private:
    Actions cancelIfStillPending(TrackId nowPlaying, bool stopAfterCurrentSet);

    bool m_armed = false;
    TrackId m_armedTrack = 0;
};

} // namespace queue_stop
