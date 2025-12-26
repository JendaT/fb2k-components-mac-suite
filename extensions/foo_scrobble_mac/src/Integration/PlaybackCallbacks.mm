//
//  PlaybackCallbacks.mm
//  foo_scrobble_mac
//
//  foobar2000 playback callbacks for scrobbling
//

#include "../fb2k_sdk.h"
#import "../Core/ScrobbleTrack.h"
#import "../Core/ScrobbleRules.h"
#import "../Core/ScrobbleConfig.h"
#import "../Services/ScrobbleService.h"

#include <mutex>

namespace {

class ScrobblePlayCallback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track |
               flag_on_playback_stop |
               flag_on_playback_seek |
               flag_on_playback_time |
               flag_on_playback_edited |
               flag_on_playback_dynamic_info_track;
    }

    void on_playback_new_track(metadb_handle_ptr track) override {
        @autoreleasepool {
            std::lock_guard<std::mutex> lock(m_mutex);

            console::info("[Scrobble] on_playback_new_track called");

            try {
                // Finalize previous track if needed
                if (m_currentTrack && canScrobble()) {
                    console::info("[Scrobble] Finalizing previous track");
                    finalizeTrackLocked();
                }

                // Reset tracking state
                m_accumulatedTime = 0;
                m_lastPositionUpdate = 0;
                m_scrobbled = false;
                m_sentNowPlaying = false;
                m_trackStartTime = (int64_t)[[NSDate date] timeIntervalSince1970];

                // Extract track info
                m_currentTrack = extractTrackInfo(track);

                if (m_currentTrack && m_currentTrack.isValid) {
                    FB2K_console_formatter() << "[Scrobble] New track: "
                        << m_currentTrack.artist.UTF8String << " - "
                        << m_currentTrack.title.UTF8String
                        << " (duration: " << m_currentTrack.duration << "s)";
                } else {
                    console::info("[Scrobble] Track extraction failed or invalid");
                }
            } catch (...) {
                FB2K_console_formatter() << "[Scrobble] Exception in on_playback_new_track";
            }
        }
    }

    void on_playback_time(double time) override {
        @autoreleasepool {
            std::lock_guard<std::mutex> lock(m_mutex);

            try {
                if (!m_currentTrack) return;

                // Accumulate actual playback time (handles seeks)
                double delta = time - m_lastPositionUpdate;
                if (delta > 0 && delta < 2.0) {  // Normal playback progression
                    m_accumulatedTime += delta;
                }
                m_lastPositionUpdate = time;

                // Send Now Playing after threshold
                if (!m_sentNowPlaying && m_accumulatedTime >= ScrobbleRules::kNowPlayingThreshold) {
                    m_sentNowPlaying = true;
                    ScrobbleTrack* track = [m_currentTrack copy];
                    FB2K_console_formatter() << "[Scrobble] Sending Now Playing: "
                        << track.artist.UTF8String << " - " << track.title.UTF8String;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[ScrobbleService shared] sendNowPlaying:track];
                    });
                }

                // Check if we can scrobble now
                if (!m_scrobbled && canScrobble()) {
                    m_scrobbled = true;
                    finalizeTrackLocked();
                }
            } catch (...) {}
        }
    }

    void on_playback_stop(play_control::t_stop_reason reason) override {
        @autoreleasepool {
            std::lock_guard<std::mutex> lock(m_mutex);

            try {
                // Don't finalize if just switching tracks
                if (reason != play_control::stop_reason_starting_another) {
                    if (m_currentTrack && canScrobble()) {
                        finalizeTrackLocked();
                    }
                    m_currentTrack = nil;
                }
            } catch (...) {}
        }
    }

    void on_playback_seek(double time) override {
        std::lock_guard<std::mutex> lock(m_mutex);
        // Reset position tracking but preserve accumulated time
        m_lastPositionUpdate = time;
    }

    void on_playback_edited(metadb_handle_ptr track) override {
        @autoreleasepool {
            std::lock_guard<std::mutex> lock(m_mutex);

            // Track metadata was edited - update our copy
            try {
                ScrobbleTrack* updated = extractTrackInfo(track);
                if (updated && updated.isValid) {
                    // Preserve accumulated time and state
                    m_currentTrack = updated;
                }
            } catch (...) {}
        }
    }

    void on_playback_dynamic_info_track(const file_info& info) override {
        // Dynamic info changed (e.g., streaming metadata)
        // We could update track info here if needed
    }

    // Required overrides that we don't use
    void on_playback_starting(play_control::t_track_command cmd, bool paused) override {}
    void on_playback_pause(bool state) override {}
    void on_playback_dynamic_info(const file_info& info) override {}
    void on_volume_change(float volume) override {}

private:
    std::mutex m_mutex;
    ScrobbleTrack* m_currentTrack = nil;
    double m_accumulatedTime = 0;
    double m_lastPositionUpdate = 0;
    int64_t m_trackStartTime = 0;
    bool m_scrobbled = false;
    bool m_sentNowPlaying = false;

    /// Check if current track meets scrobble criteria
    bool canScrobble() {
        if (!m_currentTrack || !m_currentTrack.isValid) {
            return false;
        }

        return ScrobbleRules::canScrobble(m_currentTrack.duration, m_accumulatedTime);
    }

    /// Submit track for scrobbling (must hold mutex)
    void finalizeTrackLocked() {
        if (!m_currentTrack) return;

        // Set the timestamp when track started playing
        m_currentTrack.timestamp = m_trackStartTime;

        ScrobbleTrack* track = [m_currentTrack copy];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[ScrobbleService shared] queueTrack:track];
        });

        m_scrobbled = true;
    }

    /// Extract track info from foobar2000 metadb handle
    ScrobbleTrack* extractTrackInfo(metadb_handle_ptr handle) {
        if (!handle.is_valid()) {
            return nil;
        }

        metadb_info_container::ptr info;
        if (!handle->get_info_ref(info)) {
            return nil;
        }

        const file_info& fi = info->info();

        // Get metadata using titleformat if available, otherwise direct access
        auto getString = [&](const char* field) -> NSString* {
            const char* value = fi.meta_get(field, 0);
            if (value && value[0]) {
                return [NSString stringWithUTF8String:value];
            }
            return nil;
        };

        NSString* artist = getString("artist");
        NSString* title = getString("title");
        NSString* album = getString("album");
        NSString* albumArtist = getString("album artist");

        // Get track number
        NSInteger trackNumber = 0;
        const char* tn = fi.meta_get("tracknumber", 0);
        if (tn) {
            trackNumber = atoi(tn);
        }

        // Get duration
        double duration = fi.get_length();

        // Skip if missing required fields
        if (!artist.length || !title.length) {
            return nil;
        }

        // Skip if track is too short
        if (!ScrobbleRules::isTrackLongEnough(duration)) {
            return nil;
        }

        ScrobbleTrack* track = [[ScrobbleTrack alloc] init];
        track.artist = artist;
        track.title = title;
        track.album = album ?: @"";
        track.albumArtist = albumArtist ?: @"";
        track.duration = (NSInteger)duration;
        track.trackNumber = trackNumber;
        // Note: timestamp is initialized to current time in init
        // It will be updated to track start time when scrobbling

        return track;
    }
};

FB2K_SERVICE_FACTORY(ScrobblePlayCallback);

} // anonymous namespace
