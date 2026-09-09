//
//  PlaybackCallbacks.mm
//  foo_scrobble_mac
//
//  foobar2000 playback callbacks for scrobbling
//

#include "../fb2k_sdk.h"
#import "../Core/ScrobbleTrack.h"
#import "../Core/ScrobbleRules.h"
#import "../Core/PlaybackTracker.h"
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
                ScrobbleTrack* previous = m_currentTrack;
                m_currentTrack = extractTrackInfo(track);

                int64_t startTime = (int64_t)[[NSDate date] timeIntervalSince1970];
                scrobble::PlaybackDecision decision = m_tracker.beginTrack(
                    m_currentTrack != nil,
                    m_currentTrack ? (double)m_currentTrack.duration : 0.0,
                    m_currentTrack ? m_currentTrack.isValid : false,
                    startTime);

                if (decision.scrobble && previous) {
                    console::info("[Scrobble] Finalizing previous track");
                    queueScrobble(previous, decision.timestamp);
                }

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

                scrobble::PlaybackDecision decision = m_tracker.onTime(time);

                if (decision.sendNowPlaying) {
                    ScrobbleTrack* track = [m_currentTrack copy];
                    FB2K_console_formatter() << "[Scrobble] Sending Now Playing: "
                        << track.artist.UTF8String << " - " << track.title.UTF8String;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[ScrobbleService shared] sendNowPlaying:track];
                    });
                }

                if (decision.scrobble) {
                    queueScrobble(m_currentTrack, decision.timestamp);
                }
            } catch (...) {
                FB2K_console_formatter() << "[Scrobble] Exception in on_playback_time";
            }
        }
    }

    void on_playback_stop(play_control::t_stop_reason reason) override {
        @autoreleasepool {
            std::lock_guard<std::mutex> lock(m_mutex);

            try {
                bool startingAnother = (reason == play_control::stop_reason_starting_another);
                scrobble::PlaybackDecision decision = m_tracker.onStop(startingAnother);

                if (decision.scrobble && m_currentTrack) {
                    queueScrobble(m_currentTrack, decision.timestamp);
                }

                if (!startingAnother) {
                    m_currentTrack = nil;

                    // Clear Now Playing indicator in widget
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [[ScrobbleService shared] clearNowPlaying];
                    });
                }
            } catch (...) {
                FB2K_console_formatter() << "[Scrobble] Exception in on_playback_stop";
            }
        }
    }

    void on_playback_seek(double time) override {
        std::lock_guard<std::mutex> lock(m_mutex);
        // Resync position tracking but preserve accumulated time
        m_tracker.onSeek(time);
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
                    m_tracker.onTrackEdited((double)updated.duration, updated.isValid);
                }
            } catch (...) {
                FB2K_console_formatter() << "[Scrobble] Exception in on_playback_edited";
            }
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
    scrobble::PlaybackTracker m_tracker;

    /// Stamp the track with its start-of-playback timestamp and hand it to
    /// the service (must hold mutex)
    void queueScrobble(ScrobbleTrack* track, int64_t timestamp) {
        track.timestamp = timestamp;
        ScrobbleTrack* copy = [track copy];

        dispatch_async(dispatch_get_main_queue(), ^{
            [[ScrobbleService shared] queueTrack:copy];
        });
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
