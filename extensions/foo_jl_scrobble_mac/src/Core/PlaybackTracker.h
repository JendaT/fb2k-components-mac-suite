//
//  PlaybackTracker.h
//  foo_jl_scrobble_mac
//
//  Pure playback-to-scrobble state machine, extracted from the
//  play_callback shell so the timing heuristics are unit-testable.
//  No foobar2000 SDK and no Foundation: consumes plain doubles/int64_t
//  event data, emits decisions; the caller owns track metadata,
//  threading, and dispatch to ScrobbleService.
//

#pragma once

#include <cstdint>

#include "ScrobbleRules.h"

namespace scrobble {

/// What the caller should do after feeding an event to the tracker.
/// When `scrobble` is set, the track must be stamped with `timestamp`
/// (the time playback of that track STARTED, not when it qualified).
struct PlaybackDecision {
    bool sendNowPlaying = false;
    bool scrobble = false;
    int64_t timestamp = 0;
};

class PlaybackTracker {
public:
    /// A new track begins. Returns the decision for the PREVIOUS track:
    /// it is scrobbled iff it earned enough playtime and was not already
    /// scrobbled. State then resets for the new track.
    /// @param hasTrack  false if metadata extraction failed (no tracking occurs)
    /// @param duration  track length in seconds
    /// @param valid     track metadata passes validation (ScrobbleTrack.isValid)
    /// @param startTime wall-clock unix time playback starts (becomes the
    ///                  scrobble timestamp for THIS track when it qualifies)
    PlaybackDecision beginTrack(bool hasTrack, double duration, bool valid,
                                int64_t startTime) {
        PlaybackDecision previous = finalizeDecision();

        m_accumulatedTime = 0;
        m_lastPositionUpdate = 0;
        m_scrobbled = false;
        m_sentNowPlaying = false;
        m_trackStartTime = startTime;
        m_hasTrack = hasTrack;
        m_duration = duration;
        m_valid = valid;

        return previous;
    }

    /// Playback position advanced to `time` (seconds into the track).
    /// Accumulates only plausible forward progress: deltas that are
    /// negative or >= 2s are seeks/jumps and must not count as listening.
    PlaybackDecision onTime(double time) {
        PlaybackDecision decision;
        if (!m_hasTrack) return decision;

        double delta = time - m_lastPositionUpdate;
        if (delta > 0 && delta < 2.0) {  // Normal playback progression
            m_accumulatedTime += delta;
        }
        m_lastPositionUpdate = time;

        if (!m_sentNowPlaying &&
            ScrobbleRules::isEligibleForNowPlaying(m_accumulatedTime)) {
            m_sentNowPlaying = true;
            decision.sendNowPlaying = true;
        }

        if (!m_scrobbled && canScrobble()) {
            m_scrobbled = true;
            decision.scrobble = true;
            decision.timestamp = m_trackStartTime;
        }
        return decision;
    }

    /// User seeked: resync position tracking, keep accumulated listening time.
    void onSeek(double time) {
        m_lastPositionUpdate = time;
    }

    /// Playback stopped. When `startingAnother`, the upcoming beginTrack()
    /// finalizes the current track instead, so nothing happens here.
    /// Otherwise the current track is scrobbled iff it qualifies and was
    /// not already scrobbled mid-play, then tracking ends.
    PlaybackDecision onStop(bool startingAnother) {
        PlaybackDecision decision;
        if (startingAnother) return decision;

        decision = finalizeDecision();
        m_hasTrack = false;
        return decision;
    }

    /// Track metadata was edited in place: duration/validity may change,
    /// accumulated time and scrobble state are preserved.
    void onTrackEdited(double duration, bool valid) {
        if (!m_hasTrack) return;
        m_duration = duration;
        m_valid = valid;
    }

    // Introspection (for logging / assertions)
    bool hasTrack() const { return m_hasTrack; }
    bool scrobbled() const { return m_scrobbled; }
    bool sentNowPlaying() const { return m_sentNowPlaying; }
    double accumulatedTime() const { return m_accumulatedTime; }

private:
    bool canScrobble() const {
        return m_hasTrack && m_valid &&
               ScrobbleRules::canScrobble(m_duration, m_accumulatedTime);
    }

    PlaybackDecision finalizeDecision() {
        PlaybackDecision decision;
        if (!m_scrobbled && canScrobble()) {
            m_scrobbled = true;
            decision.scrobble = true;
            decision.timestamp = m_trackStartTime;
        }
        return decision;
    }

    bool m_hasTrack = false;
    bool m_valid = false;
    double m_duration = 0;
    double m_accumulatedTime = 0;
    double m_lastPositionUpdate = 0;
    int64_t m_trackStartTime = 0;
    bool m_scrobbled = false;
    bool m_sentNowPlaying = false;
};

}  // namespace scrobble
