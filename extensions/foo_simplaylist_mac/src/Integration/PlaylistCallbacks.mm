//
//  PlaylistCallbacks.mm
//  foo_simplaylist_mac
//
//  Callback handlers for playlist and playback events
//

#import "PlaylistCallbacks.h"
#import "../UI/SimPlaylistController.h"
#import <mutex>
#import <vector>

// Global controller storage
static std::mutex g_controllersMutex;
static std::vector<__weak SimPlaylistController*> g_controllers;

// Callback manager implementation
SimPlaylistCallbackManager& SimPlaylistCallbackManager::instance() {
    static SimPlaylistCallbackManager manager;
    return manager;
}

void SimPlaylistCallbackManager::registerController(SimPlaylistController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    for (const auto& weak : g_controllers) {
        if (weak == controller) return;
    }
    g_controllers.push_back(controller);
}

void SimPlaylistCallbackManager::unregisterController(SimPlaylistController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    g_controllers.erase(
        std::remove_if(g_controllers.begin(), g_controllers.end(),
            [controller](const __weak SimPlaylistController* weak) {
                return weak == nil || weak == controller;
            }),
        g_controllers.end()
    );
}

void SimPlaylistCallbackManager::onPlaylistSwitched() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handlePlaylistSwitched];
        }
    });
}

void SimPlaylistCallbackManager::onItemsAdded(t_size base, t_size count) {
    NSInteger b = base;
    NSInteger cnt = count;
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handleItemsAdded:b count:cnt];
        }
    });
}

void SimPlaylistCallbackManager::onItemsRemoved() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handleItemsRemoved];
        }
    });
}

void SimPlaylistCallbackManager::onItemsReordered() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handleItemsReordered];
        }
    });
}

void SimPlaylistCallbackManager::onSelectionChanged() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handleSelectionChanged];
        }
    });
}

void SimPlaylistCallbackManager::onFocusChanged(t_size from, t_size to) {
    NSInteger f = (from == SIZE_MAX) ? -1 : from;
    NSInteger t = (to == SIZE_MAX) ? -1 : to;
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handleFocusChanged:f to:t];
        }
    });
}

void SimPlaylistCallbackManager::onItemsModified() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handleItemsModified];
        }
    });
}

void SimPlaylistCallbackManager::onPlaybackNewTrack(metadb_handle_ptr track) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handlePlaybackNewTrack:track];
        }
    });
}

void SimPlaylistCallbackManager::onPlaybackStopped() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (__weak SimPlaylistController* weak : g_controllers) {
            SimPlaylistController* c = weak;
            if (c) [c handlePlaybackStopped];
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
};

// Pointer - created in on_init, destroyed in on_quit
static simplaylist_playlist_callback* g_playlist_callback = nullptr;

void SimPlaylistCallbackManager::initCallbacks() {
    if (!g_playlist_callback) {
        g_playlist_callback = new simplaylist_playlist_callback();
    }
}

void SimPlaylistCallbackManager::shutdownCallbacks() {
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
