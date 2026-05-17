#import "PlayVancedCallbacks.h"
#import "../Core/ArtworkFetcher.h"
#import "../UI/PlayVancedController.h"
#import <mutex>

static std::mutex g_controllersMutex;
static NSHashTable<PlayVancedController *> *g_controllers;

PlayVancedCallbackManager& PlayVancedCallbackManager::instance() {
    static PlayVancedCallbackManager manager;
    return manager;
}

void PlayVancedCallbackManager::registerController(PlayVancedController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    if (!g_controllers) {
        g_controllers = [NSHashTable weakObjectsHashTable];
    }
    [g_controllers addObject:controller];
}

void PlayVancedCallbackManager::unregisterController(PlayVancedController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    [g_controllers removeObject:controller];
}

void PlayVancedCallbackManager::onPlaybackNewTrack(metadb_handle_ptr track) {
    {
        std::lock_guard<std::mutex> lock(m_trackMutex);
        m_playingTrack = track;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (PlayVancedController *c in g_controllers) {
            [c handleNewTrack:track];
        }
    });
}

void PlayVancedCallbackManager::onPlaybackStop(play_control::t_stop_reason reason) {
    {
        std::lock_guard<std::mutex> lock(m_trackMutex);
        m_playingTrack.release();
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (PlayVancedController *c in g_controllers) {
            [c handlePlaybackStop];
        }
    });
}

void PlayVancedCallbackManager::onPlaybackPause(bool paused) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (PlayVancedController *c in g_controllers) {
            [c handlePlaybackPause:paused];
        }
    });
}

void PlayVancedCallbackManager::onPlaybackTime(double time) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (PlayVancedController *c in g_controllers) {
            [c handlePlaybackTime:time];
        }
    });
}

void PlayVancedCallbackManager::onPlaybackSeek(double time) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (PlayVancedController *c in g_controllers) {
            [c handlePlaybackSeek:time];
        }
    });
}

void PlayVancedCallbackManager::onVolumeChange(float newVolDb) {
    float normalized = (newVolDb <= playback_control::volume_mute) ? 0.0f :
                       powf(10.0f, newVolDb / 20.0f);
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (PlayVancedController *c in g_controllers) {
            [c handleVolumeChanged:normalized];
        }
    });
}

void PlayVancedCallbackManager::onSelectionChanged() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (PlayVancedController *c in g_controllers) {
            [c handleSelectionChanged];
        }
    });
}

void PlayVancedCallbackManager::onPlaybackOrderChanged(t_size order) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (PlayVancedController *c in g_controllers) {
            [c handlePlaybackOrderChanged:(NSInteger)order];
        }
    });
}

metadb_handle_ptr PlayVancedCallbackManager::getCurrentPlayingTrack() const {
    std::lock_guard<std::mutex> lock(m_trackMutex);
    return m_playingTrack;
}

void PlayVancedCallbackManager_registerController(PlayVancedController* controller) {
    PlayVancedCallbackManager::instance().registerController(controller);
}

void PlayVancedCallbackManager_unregisterController(PlayVancedController* controller) {
    PlayVancedCallbackManager::instance().unregisterController(controller);
}

// SDK play_callback_static
class playvanced_play_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track |
               flag_on_playback_stop |
               flag_on_playback_pause |
               flag_on_playback_time |
               flag_on_playback_seek |
               flag_on_volume_change;
    }

    void on_playback_new_track(metadb_handle_ptr p_track) override {
        PlayVancedCallbackManager::instance().onPlaybackNewTrack(p_track);
    }

    void on_playback_stop(play_control::t_stop_reason p_reason) override {
        PlayVancedCallbackManager::instance().onPlaybackStop(p_reason);
    }

    void on_playback_pause(bool p_state) override {
        PlayVancedCallbackManager::instance().onPlaybackPause(p_state);
    }

    void on_playback_time(double p_time) override {
        PlayVancedCallbackManager::instance().onPlaybackTime(p_time);
    }

    void on_playback_seek(double p_time) override {
        PlayVancedCallbackManager::instance().onPlaybackSeek(p_time);
    }

    void on_playback_starting(play_control::t_track_command p_command, bool p_paused) override {}
    void on_playback_edited(metadb_handle_ptr p_track) override {}
    void on_playback_dynamic_info(const file_info& p_info) override {}
    void on_playback_dynamic_info_track(const file_info& p_info) override {}
    void on_volume_change(float p_new_val) override {
        PlayVancedCallbackManager::instance().onVolumeChange(p_new_val);
    }
};

FB2K_SERVICE_FACTORY(playvanced_play_callback);

// SDK playlist_callback_static for selection tracking
class playvanced_playlist_callback : public playlist_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_items_selection_change |
               flag_on_playlist_activate |
               flag_on_playback_order_changed;
    }

    void on_items_selection_change(t_size p_playlist, const bit_array& p_affected, const bit_array& p_state) override {
        auto pm = playlist_manager::get();
        if (pm.is_valid() && pm->get_active_playlist() == p_playlist) {
            PlayVancedCallbackManager::instance().onSelectionChanged();
        }
    }

    void on_playlist_activate(t_size p_old, t_size p_new) override {
        PlayVancedCallbackManager::instance().onSelectionChanged();
    }

    void on_items_added(t_size, t_size, const pfc::list_base_const_t<metadb_handle_ptr>&, const bit_array&) override {}
    void on_items_reordered(t_size, const t_size*, t_size) override {}
    void on_items_removing(t_size, const bit_array&, t_size, t_size) override {}
    void on_items_removed(t_size, const bit_array&, t_size, t_size) override {}
    void on_item_focus_change(t_size, t_size, t_size) override {}
    void on_items_modified(t_size, const bit_array&) override {}
    void on_items_modified_fromplayback(t_size, const bit_array&, play_control::t_display_level) override {}
    void on_items_replaced(t_size, const bit_array&, const pfc::list_base_const_t<t_on_items_replaced_entry>&) override {}
    void on_item_ensure_visible(t_size, t_size) override {}
    void on_playlist_created(t_size, const char*, t_size) override {}
    void on_playlists_reorder(const t_size*, t_size) override {}
    void on_playlists_removing(const bit_array&, t_size, t_size) override {}
    void on_playlists_removed(const bit_array&, t_size, t_size) override {}
    void on_playlist_renamed(t_size, const char*, t_size) override {}
    void on_default_format_changed() override {}
    void on_playback_order_changed(t_size p_new_order) override {
        PlayVancedCallbackManager::instance().onPlaybackOrderChanged(p_new_order);
    }
    void on_playlist_locked(t_size, bool) override {}
};

FB2K_SERVICE_FACTORY(playvanced_playlist_callback);
