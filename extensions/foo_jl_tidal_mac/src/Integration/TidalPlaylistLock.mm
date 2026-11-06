//
//  TidalPlaylistLock.mm
//  foo_jl_tidal_mac
//
//  Playlist lock for TIDAL-synced playlists.
//  Blocks rename and delete operations while allowing track manipulation.
//

#include "TidalPlaylistLock.h"
#include "../Core/TidalConfig.h"
#include <mutex>

namespace tidal {

static const char* kLockName = "TIDAL Sync";

// Track installed locks by playlist index so we can remove them
static std::map<t_size, service_ptr_t<playlist_lock>> g_installedLocks;
static std::mutex g_locksMutex;

#pragma mark - playlist_lock implementation

bool TidalPlaylistLock::query_items_add(t_size, const pfc::list_base_const_t<metadb_handle_ptr>&,
                                        const bit_array&) {
    return true;  // Allow adding tracks
}

bool TidalPlaylistLock::query_items_reorder(const t_size*, t_size) {
    return true;  // Allow reordering
}

bool TidalPlaylistLock::query_items_remove(const bit_array&, bool) {
    return true;  // Allow removing tracks
}

bool TidalPlaylistLock::query_item_replace(t_size, const metadb_handle_ptr&,
                                           const metadb_handle_ptr&) {
    return true;  // Allow replacing items
}

bool TidalPlaylistLock::query_playlist_rename(const char*, t_size) {
    return false;  // Block renaming
}

bool TidalPlaylistLock::query_playlist_remove() {
    return false;  // Block deletion
}

bool TidalPlaylistLock::execute_default_action(t_size) {
    return false;  // Fall through to default (start playback)
}

void TidalPlaylistLock::on_playlist_index_change(t_size p_new_index) {
    std::lock_guard<std::mutex> guard(g_locksMutex);
    for (auto it = g_installedLocks.begin(); it != g_installedLocks.end(); ++it) {
        if (it->second.get_ptr() == this) {
            auto lock = it->second;
            g_installedLocks.erase(it);
            g_installedLocks[p_new_index] = lock;
            break;
        }
    }
}

void TidalPlaylistLock::on_playlist_remove() {
    std::lock_guard<std::mutex> guard(g_locksMutex);
    for (auto it = g_installedLocks.begin(); it != g_installedLocks.end(); ++it) {
        if (it->second.get_ptr() == this) {
            g_installedLocks.erase(it);
            break;
        }
    }
}

void TidalPlaylistLock::get_lock_name(pfc::string_base& p_out) {
    p_out = kLockName;
}

void TidalPlaylistLock::show_ui() {
    // No dedicated UI for this lock
}

t_uint32 TidalPlaylistLock::get_filter_mask() {
    return filter_rename | filter_remove_playlist;
}

#pragma mark - Lock management

bool installSyncLock(t_size playlistIndex) {
    auto pm = playlist_manager::get();
    if (pm->playlist_lock_is_present(playlistIndex)) {
        return false;
    }

    auto lock = fb2k::service_new<TidalPlaylistLock>();
    if (pm->playlist_lock_install(playlistIndex, lock)) {
        std::lock_guard<std::mutex> guard(g_locksMutex);
        g_installedLocks[playlistIndex] = lock;
        logDebug("Installed TIDAL sync lock on playlist");
        return true;
    }
    return false;
}

bool removeSyncLock(t_size playlistIndex) {
    std::lock_guard<std::mutex> guard(g_locksMutex);
    auto it = g_installedLocks.find(playlistIndex);
    if (it == g_installedLocks.end()) {
        return false;
    }

    auto pm = playlist_manager::get();
    if (pm->playlist_lock_uninstall(playlistIndex, it->second)) {
        g_installedLocks.erase(it);
        logDebug("Removed TIDAL sync lock from playlist");
        return true;
    }
    return false;
}

bool hasSyncLock(t_size playlistIndex) {
    std::lock_guard<std::mutex> guard(g_locksMutex);
    return g_installedLocks.find(playlistIndex) != g_installedLocks.end();
}

} // namespace tidal
