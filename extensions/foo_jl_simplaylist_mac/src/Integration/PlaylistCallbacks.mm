//
//  PlaylistCallbacks.mm
//  foo_simplaylist_mac
//
//  Callback handlers for playlist and playback events
//

#import "PlaylistCallbacks.h"
#import "../UI/SimPlaylistController.h"
#import <mutex>

// Global controller storage - NSHashTable with weak memory properly supports ARC zeroing
static std::mutex g_controllersMutex;
static NSHashTable<SimPlaylistController *> *g_controllers;

// Callback manager implementation
SimPlaylistCallbackManager& SimPlaylistCallbackManager::instance() {
    static SimPlaylistCallbackManager manager;
    return manager;
}

void SimPlaylistCallbackManager::registerController(SimPlaylistController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    if (!g_controllers) {
        g_controllers = [NSHashTable weakObjectsHashTable];
    }
    [g_controllers addObject:controller];
}

void SimPlaylistCallbackManager::unregisterController(SimPlaylistController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    [g_controllers removeObject:controller];
}

void SimPlaylistCallbackManager::onPlaylistSwitched() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handlePlaylistSwitched];
        }
    });
}

void SimPlaylistCallbackManager::onItemsAdded(t_size base, t_size count) {
    NSInteger b = base;
    NSInteger cnt = count;
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleItemsAdded:b count:cnt];
        }
    });
}

void SimPlaylistCallbackManager::onItemsRemoved() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleItemsRemoved];
        }
    });
}

void SimPlaylistCallbackManager::onItemsReordered() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleItemsReordered];
        }
    });
}

void SimPlaylistCallbackManager::onSelectionChanged() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleSelectionChanged];
        }
    });
}

void SimPlaylistCallbackManager::onFocusChanged(t_size from, t_size to) {
    NSInteger f = (from == SIZE_MAX) ? -1 : from;
    NSInteger t = (to == SIZE_MAX) ? -1 : to;
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleFocusChanged:f to:t];
        }
    });
}

void SimPlaylistCallbackManager::onItemsModified() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleItemsModified];
        }
    });
}

void SimPlaylistCallbackManager::onEnsureVisible(t_size idx) {
    NSInteger i = idx;
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleEnsureVisible:i];
        }
    });
}

void SimPlaylistCallbackManager::onPlaybackNewTrack(metadb_handle_ptr track) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handlePlaybackNewTrack:track];
        }
    });
}

void SimPlaylistCallbackManager::onPlaybackStopped() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handlePlaybackStopped];
        }
    });
}

void SimPlaylistCallbackManager::onQueueChanged() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleQueueChanged];
        }
    });
}

// Convenience functions
void SimPlaylistCallbackManager_registerController(SimPlaylistController* controller) {
    SimPlaylistCallbackManager::instance().registerController(controller);
}

void SimPlaylistCallbackManager_unregisterController(SimPlaylistController* controller) {
    SimPlaylistCallbackManager::instance().unregisterController(controller);
}

// Playlist callback implementation - created at runtime, not static init
class simplaylist_playlist_callback : public playlist_callback_single_impl_base {
public:
    simplaylist_playlist_callback() : playlist_callback_single_impl_base(
        flag_on_items_added |
        flag_on_items_removed |
        flag_on_items_reordered |
        flag_on_items_selection_change |
        flag_on_item_focus_change |
        flag_on_items_modified |
        flag_on_playlist_switch
    ) {}

    void on_items_added(t_size base, metadb_handle_list_cref data, const bit_array& selection) override {
        SimPlaylistCallbackManager::instance().onItemsAdded(base, data.get_count());
    }

    void on_items_removed(const bit_array& mask, t_size old_count, t_size new_count) override {
        SimPlaylistCallbackManager::instance().onItemsRemoved();
    }

    void on_items_reordered(const t_size* order, t_size count) override {
        SimPlaylistCallbackManager::instance().onItemsReordered();
    }

    void on_items_selection_change(const bit_array& affected, const bit_array& state) override {
        SimPlaylistCallbackManager::instance().onSelectionChanged();
    }

    void on_item_focus_change(t_size from, t_size to) override {
        SimPlaylistCallbackManager::instance().onFocusChanged(from, to);
    }

    void on_items_modified(const bit_array& mask) override {
        SimPlaylistCallbackManager::instance().onItemsModified();
    }

    void on_playlist_switch() override {
        SimPlaylistCallbackManager::instance().onPlaylistSwitched();
    }

    void on_item_ensure_visible(t_size p_idx) override {
        SimPlaylistCallbackManager::instance().onEnsureVisible(p_idx);
    }
};

// Pointer - created in on_init, destroyed in on_quit
static simplaylist_playlist_callback* g_playlist_callback = nullptr;

void SimPlaylistCallbackManager::initCallbacks() {
    if (!g_playlist_callback) {
        g_playlist_callback = new simplaylist_playlist_callback();
    }
}

void SimPlaylistCallbackManager::onShutdown() {
    // Save group cache for all registered controllers before shutdown.
    // Must run on main thread (accesses UI state), and we're already on main in on_quit.
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    for (SimPlaylistController *c in g_controllers) {
        [c saveGroupCacheForCurrentPlaylist];
    }
}

void SimPlaylistCallbackManager::shutdownCallbacks() {
    onShutdown();
    delete g_playlist_callback;
    g_playlist_callback = nullptr;
}

// Playback callback implementation
class simplaylist_playback_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track | flag_on_playback_stop;
    }

    void on_playback_new_track(metadb_handle_ptr track) override {
        SimPlaylistCallbackManager::instance().onPlaybackNewTrack(track);
    }

    void on_playback_stop(play_control::t_stop_reason reason) override {
        SimPlaylistCallbackManager::instance().onPlaybackStopped();
    }

    // Unused callbacks
    void on_playback_starting(play_control::t_track_command cmd, bool paused) override {}
    void on_playback_seek(double time) override {}
    void on_playback_pause(bool paused) override {}
    void on_playback_edited(metadb_handle_ptr track) override {}
    void on_playback_dynamic_info(const file_info& info) override {}
    void on_playback_dynamic_info_track(const file_info& info) override {}
    void on_playback_time(double time) override {}
    void on_volume_change(float newVal) override {}
};

FB2K_SERVICE_FACTORY(simplaylist_playback_callback);

// Playback queue callback - notifies when queue contents change
class simplaylist_queue_callback : public playback_queue_callback {
public:
    void on_changed(t_change_origin origin) override {
        SimPlaylistCallbackManager::instance().onQueueChanged();
    }
};

FB2K_SERVICE_FACTORY(simplaylist_queue_callback);
