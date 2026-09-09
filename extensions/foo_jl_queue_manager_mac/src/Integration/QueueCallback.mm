//
//  QueueCallback.mm
//  foo_jl_queue_manager
//
//  Service factory for playback_queue_callback
//  Delegates to QueueCallbackManager singleton
//

#import "QueueCallbackManager.h"
#include <foobar2000/SDK/foobar2000.h>

namespace {

class queue_callback_impl : public playback_queue_callback {
public:
    void on_changed(t_change_origin origin) override {
        QueueCallbackManager::instance().onQueueChanged(origin);
    }
};

FB2K_SERVICE_FACTORY(queue_callback_impl);

class queue_play_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track |
               flag_on_playback_stop |
               flag_on_playback_pause |
               flag_on_playback_time;
    }

    void on_playback_new_track(metadb_handle_ptr p_track) override {
        QueueCallbackManager::instance().onPlaybackNewTrack(p_track);
    }

    void on_playback_stop(play_control::t_stop_reason p_reason) override {
        QueueCallbackManager::instance().onPlaybackStop(p_reason);
    }

    void on_playback_pause(bool p_state) override {
        QueueCallbackManager::instance().onPlaybackPause(p_state);
    }

    void on_playback_time(double p_time) override {
        QueueCallbackManager::instance().onPlaybackTime(p_time);
    }

    void on_playback_starting(play_control::t_track_command, bool) override {}
    void on_playback_seek(double) override {}
    void on_playback_edited(metadb_handle_ptr) override {}
    void on_playback_dynamic_info(const file_info&) override {}
    void on_playback_dynamic_info_track(const file_info&) override {}
    void on_volume_change(float) override {}
};

FB2K_SERVICE_FACTORY(queue_play_callback);

class queue_manager_init : public initquit {
public:
    void on_init() override {
        QueueCallbackManager::instance();
        QueueCallbackManager::instance().restoreQueueState();
        console::info("[Queue Manager] Initialized");
    }

    void on_quit() override {
        QueueCallbackManager::instance().saveQueueState();
    }
};

FB2K_SERVICE_FACTORY(queue_manager_init);

} // namespace
