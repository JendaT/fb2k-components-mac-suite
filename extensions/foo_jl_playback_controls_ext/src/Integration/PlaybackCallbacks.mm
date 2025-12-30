//
//  PlaybackCallbacks.mm
//  foo_jl_playback_controls_ext
//
//  Playback event callbacks implementation
//

#include "PlaybackCallbacks.h"
#import "../UI/PlaybackControlsController.h"

namespace {

class PlaybackControlsCallback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track |
               flag_on_playback_stop |
               flag_on_playback_pause |
               flag_on_playback_seek |
               flag_on_playback_time |
               flag_on_volume_change |
               flag_on_playback_edited |
               flag_on_playback_dynamic_info_track;
    }

    void on_playback_new_track(metadb_handle_ptr track) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackControlsController *controller = [PlaybackControlsController activeController];
            [controller updatePlaybackState];
            [controller updateTrackInfo];
        });
    }

    void on_playback_stop(play_control::t_stop_reason reason) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackControlsController *controller = [PlaybackControlsController activeController];
            [controller updatePlaybackState];
            [controller updateTrackInfo];
        });
    }

    void on_playback_pause(bool state) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackControlsController *controller = [PlaybackControlsController activeController];
            [controller updatePlaybackState];
        });
    }

    void on_playback_seek(double time) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackControlsController *controller = [PlaybackControlsController activeController];
            [controller updateTrackInfo];
        });
    }

    void on_playback_time(double time) override {
        // Called every second - update time display
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackControlsController *controller = [PlaybackControlsController activeController];
            [controller updateTrackInfo];
        });
    }

    void on_volume_change(float newVolume) override {
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackControlsController *controller = [PlaybackControlsController activeController];
            [controller updateVolume:newVolume];
        });
    }

    void on_playback_edited(metadb_handle_ptr track) override {
        // Track metadata was edited while playing
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackControlsController *controller = [PlaybackControlsController activeController];
            [controller updateTrackInfo];
        });
    }

    void on_playback_dynamic_info_track(const file_info& info) override {
        // Stream title changed or similar
        dispatch_async(dispatch_get_main_queue(), ^{
            PlaybackControlsController *controller = [PlaybackControlsController activeController];
            [controller updateTrackInfo];
        });
    }

    // Required but unused callbacks
    void on_playback_starting(play_control::t_track_command cmd, bool paused) override {}
    void on_playback_dynamic_info(const file_info& info) override {}
};

FB2K_SERVICE_FACTORY(PlaybackControlsCallback);

} // anonymous namespace
