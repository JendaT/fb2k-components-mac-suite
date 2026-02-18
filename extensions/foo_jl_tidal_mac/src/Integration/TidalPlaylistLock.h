//
//  TidalPlaylistLock.h
//  foo_jl_tidal_mac
//
//  Playlist lock for TIDAL-synced playlists.
//  Allows: add, remove, reorder tracks
//  Blocks: rename playlist, delete playlist
//

#pragma once

#include "../fb2k_sdk.h"
#include <set>

namespace tidal {

class TidalPlaylistLock : public playlist_lock {
public:
    // playlist_lock interface
    bool query_items_add(t_size p_base,
                         const pfc::list_base_const_t<metadb_handle_ptr>& p_data,
                         const bit_array& p_selection) override;
    bool query_items_reorder(const t_size* p_order, t_size p_count) override;
    bool query_items_remove(const bit_array& p_mask, bool p_force) override;
    bool query_item_replace(t_size p_index,
                            const metadb_handle_ptr& p_old,
                            const metadb_handle_ptr& p_new) override;
    bool query_playlist_rename(const char* p_new_name, t_size p_new_name_len) override;
    bool query_playlist_remove() override;
    bool execute_default_action(t_size p_item) override;
    void on_playlist_index_change(t_size p_new_index) override;
    void on_playlist_remove() override;
    void get_lock_name(pfc::string_base& p_out) override;
    void show_ui() override;
    t_uint32 get_filter_mask() override;
};

// Install a TIDAL sync lock on the specified playlist.
// Returns false if playlist is already locked or index is invalid.
bool installSyncLock(t_size playlistIndex);

// Remove TIDAL sync lock from the specified playlist.
// Returns false if playlist is not locked by us.
bool removeSyncLock(t_size playlistIndex);

// Check if the specified playlist has a TIDAL sync lock.
bool hasSyncLock(t_size playlistIndex);

} // namespace tidal
