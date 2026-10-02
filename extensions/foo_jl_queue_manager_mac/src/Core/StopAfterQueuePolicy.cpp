//
//  StopAfterQueuePolicy.cpp
//  foo_jl_queue_manager
//

#include "StopAfterQueuePolicy.h"

namespace queue_stop {

Actions StopAfterQueuePolicy::onQueueAdvancedToEmpty(bool enabled, TrackId consumed) {
    Actions a;
    if (!enabled) return a;
    a.setStopAfterCurrent = true;
    m_armed = true;
    m_armedTrack = consumed;
    return a;
}

Actions StopAfterQueuePolicy::cancelIfStillPending(TrackId nowPlaying, bool stopAfterCurrentSet) {
    Actions a;
    if (!m_armed) return a;
    // Only undo our own arming: the armed track must still be playing with
    // the flag set (otherwise it already stopped or the user changed it)
    if (stopAfterCurrentSet && m_armedTrack != 0 && nowPlaying == m_armedTrack) {
        a.clearStopAfterCurrent = true;
    }
    m_armed = false;
    m_armedTrack = 0;
    return a;
}

Actions StopAfterQueuePolicy::onQueueItemsAdded(TrackId nowPlaying, bool stopAfterCurrentSet) {
    return cancelIfStillPending(nowPlaying, stopAfterCurrentSet);
}

Actions StopAfterQueuePolicy::onSettingDisabled(TrackId nowPlaying, bool stopAfterCurrentSet) {
    return cancelIfStillPending(nowPlaying, stopAfterCurrentSet);
}

Actions StopAfterQueuePolicy::onNewTrack(TrackId track, bool stopAfterCurrentSet) {
    Actions a;
    // Unknown armed identity: cannot tell a skip from the armed track itself
    if (!m_armed || m_armedTrack == 0 || track == m_armedTrack) return a;
    // The user skipped past the last queued track; the stop we armed would
    // now end some unrelated track, so withdraw it
    if (stopAfterCurrentSet) a.clearStopAfterCurrent = true;
    m_armed = false;
    m_armedTrack = 0;
    return a;
}

Actions StopAfterQueuePolicy::onPlaybackStopped(StopReason reason, bool stopAfterCurrentSet, bool onlyOnce) {
    Actions a;
    if (!m_armed) return a;

    switch (reason) {
        case StopReason::StartingAnother:
            // Track change, not a stop; onNewTrack decides
            return a;
        case StopReason::ShuttingDown:
            // Queue end never reached; keep the setting as it is
            break;
        case StopReason::User:
        case StopReason::EndOfFile:
            // Queue has ended. Clear the flag in case fb2k left it set,
            // so it cannot stop some later track.
            if (stopAfterCurrentSet) a.clearStopAfterCurrent = true;
            if (onlyOnce) a.disableSetting = true;
            break;
    }
    m_armed = false;
    m_armedTrack = 0;
    return a;
}

} // namespace queue_stop
