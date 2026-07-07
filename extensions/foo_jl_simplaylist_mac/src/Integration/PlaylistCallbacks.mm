//
//  PlaylistCallbacks.mm
//  foo_simplaylist_mac
//
//  Callback handlers for playlist and playback events
//

#import "PlaylistCallbacks.h"
#import "../UI/SimPlaylistController.h"
#import "../Core/ConfigHelper.h"
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

void SimPlaylistCallbackManager::onItemsAdded(t_size base, t_size count, std::shared_ptr<metadb_handle_list> handles) {
    NSInteger b = base;
    NSInteger cnt = count;
    auto handlesCopy = handles;  // captured by block
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleItemsAdded:b count:cnt addedHandles:handlesCopy];
        }
    });
}

void SimPlaylistCallbackManager::onItemsRemoved(t_size newCount) {
    NSInteger nc = (NSInteger)newCount;
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleItemsRemoved:nc];
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

void SimPlaylistCallbackManager::onMetadbChanged(std::shared_ptr<metadb_handle_list> changed) {
    auto changedCopy = changed;
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (SimPlaylistController *c in g_controllers) {
            [c handleMetadbChanged:changedCopy];
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
        auto copy = std::make_shared<metadb_handle_list>(data);
        SimPlaylistCallbackManager::instance().onItemsAdded(base, data.get_count(), copy);
    }

    void on_items_removed(const bit_array& mask, t_size old_count, t_size new_count) override {
        SimPlaylistCallbackManager::instance().onItemsRemoved(new_count);
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

// Metadb IO callback — fires whenever foobar2000 reads/updates tags for any
// metadb_handle, including background reads on first playback of a previously
// unanalyzed file. Uses metadb_io_callback_dynamic_impl_base which auto-
// registers in its constructor and unregisters in the destructor.
class simplaylist_metadb_callback : public metadb_io_callback_dynamic_impl_base {
public:
    void on_changed_sorted(metadb_handle_list_cref items, bool /*fromhook*/) override {
        auto copy = std::make_shared<metadb_handle_list>(items);
        SimPlaylistCallbackManager::instance().onMetadbChanged(copy);
    }
};
static simplaylist_metadb_callback* g_metadb_callback = nullptr;

// Playing-playlist guard
//
// foobar2000 tracks the "active playlist" (shown in the UI) and the "playing
// playlist" (where the next track comes from when the current one ends)
// independently. On the Mac, browsing a library viewer (ReFacets) mirrors the
// selection into a hidden playlist and redirects the playing playlist to it,
// so finishing a track jumps playback to the browsed selection. There is no
// SDK callback for playing-playlist changes, but the redirect is detectable:
// get_playing_item_location() still reports the playlist the current track is
// actually playing from. When it disagrees with get_playing_playlist(), point
// continuation back. See docs/playing-playlist-guard.md.
//
// set_playing_playlist must not be called from inside a playlist callback
// (callbacks may only read playlist state), so checks are deferred to the
// main queue. A low-frequency timer backstops redirects that don't touch
// playlist contents (e.g. re-clicking the same ReFacets selection).

static bool g_playingGuardActive = false;
static bool g_playingGuardCheckPending = false;
static NSTimer* g_playingGuardTimer = nil;

static void runPlayingPlaylistGuardCheck() {
    if (!g_playingGuardActive) return;
    auto pm = playlist_manager::get();
    t_size itemPlaylist = SIZE_MAX, itemIndex = SIZE_MAX;
    if (!pm->get_playing_item_location(&itemPlaylist, &itemIndex)) return;
    t_size playingPlaylist = pm->get_playing_playlist();
    if (playingPlaylist == itemPlaylist) return;
    if (itemPlaylist >= pm->get_playlist_count()) return;
    if (!simplaylist_config::getConfigBool(simplaylist_config::kKeepPlayingPlaylist,
                                           simplaylist_config::kDefaultKeepPlayingPlaylist)) return;

    pfc::string8 thief = "<none>";
    if (playingPlaylist < pm->get_playlist_count()) {
        pm->playlist_get_name(playingPlaylist, thief);
    }
    pm->set_playing_playlist(itemPlaylist);
    pfc::string8 restored;
    pm->playlist_get_name(itemPlaylist, restored);
    FB2K_console_formatter() << "[SimPlaylist] Kept playback in \"" << restored
                             << "\" (playing playlist was redirected to \"" << thief << "\")";
}

static void schedulePlayingPlaylistGuardCheck() {
    if (g_playingGuardCheckPending) return;
    g_playingGuardCheckPending = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        g_playingGuardCheckPending = false;
        runPlayingPlaylistGuardCheck();
    });
}

// Watches all playlists (unlike simplaylist_playlist_callback above, which is
// active-playlist only) so the check fires when the hidden selection-mirror
// playlist is rewritten during library browsing.
class simplaylist_playing_playlist_guard : public playlist_callback_impl_base {
public:
    simplaylist_playing_playlist_guard() : playlist_callback_impl_base(
        flag_on_items_added |
        flag_on_items_removed |
        flag_on_items_replaced
    ) {}

    void on_items_added(t_size p_playlist, t_size p_start, metadb_handle_list_cref p_data, const bit_array& p_selection) override {
        schedulePlayingPlaylistGuardCheck();
    }

    void on_items_removed(t_size p_playlist, const bit_array& p_mask, t_size p_old_count, t_size p_new_count) override {
        schedulePlayingPlaylistGuardCheck();
    }

    void on_items_replaced(t_size p_playlist, const bit_array& p_mask, const pfc::list_base_const_t<t_on_items_replaced_entry>& p_data) override {
        schedulePlayingPlaylistGuardCheck();
    }
};

static simplaylist_playing_playlist_guard* g_playing_playlist_guard = nullptr;

void SimPlaylistCallbackManager::initCallbacks() {
    if (!g_playlist_callback) {
        g_playlist_callback = new simplaylist_playlist_callback();
    }
    if (!g_metadb_callback) {
        g_metadb_callback = new simplaylist_metadb_callback();
    }
    if (!g_playing_playlist_guard) {
        g_playing_playlist_guard = new simplaylist_playing_playlist_guard();
    }
    g_playingGuardActive = true;
    if (!g_playingGuardTimer) {
        g_playingGuardTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                              repeats:YES
                                                                block:^(NSTimer* timer) {
            runPlayingPlaylistGuardCheck();
        }];
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
    g_playingGuardActive = false;
    [g_playingGuardTimer invalidate];
    g_playingGuardTimer = nil;
    delete g_playing_playlist_guard;
    g_playing_playlist_guard = nullptr;
    delete g_playlist_callback;
    g_playlist_callback = nullptr;
    delete g_metadb_callback;
    g_metadb_callback = nullptr;
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
