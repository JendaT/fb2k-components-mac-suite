//
//  PlaylistCallbacks.mm
//  foo_plorg_mac
//

#include "PlaylistCallbacks.h"
#import "../Core/TreeModel.h"

#include <map>
#include <string>

namespace {

// GUID -> current foobar2000 name of every playlist. The rename callback only
// reports the new name, so this is where the previous one comes from.
// Built in plorg_init::on_init, kept current on create and rename.
// Main thread only. Stays empty without playlist_manager_v5.
std::map<GUID, std::string, pfc::predicateGUID> g_playlistNames;

void rebuildPlaylistNameCache() {
    g_playlistNames.clear();
    auto pm = playlist_manager_v5::tryGet();
    if (pm.is_empty()) return;

    const t_size count = pm->get_playlist_count();
    for (t_size i = 0; i < count; i++) {
        pfc::string8 name;
        if (pm->playlist_get_name(i, name)) {
            g_playlistNames[pm->playlist_get_guid(i)] = name.c_str();
        }
    }
}

enum class CachedName { unavailable, unknown, known };

// Stores the name the playlist at index has now. Returns known and fills
// previousName when the cache had that playlist under a name already.
CachedName rememberPlaylistName(t_size index, const char *name, std::string &previousName) {
    if (!name) return CachedName::unavailable;
    auto pm = playlist_manager_v5::tryGet();
    if (pm.is_empty() || index >= pm->get_playlist_count()) return CachedName::unavailable;

    const GUID guid = pm->playlist_get_guid(index);
    if (guid == pfc::guid_null) return CachedName::unavailable;

    auto it = g_playlistNames.find(guid);
    if (it == g_playlistNames.end()) {
        g_playlistNames.emplace(guid, name);
        return CachedName::unknown;
    }
    previousName = it->second;
    it->second = name;
    return CachedName::known;
}

// Tells the tree which playlist is playing so it can mark that row.
// No name means nothing is playing.
void postPlayingPlaylistChanged(bool playing) {
    NSString *foobarName = nil;
    if (playing) {
        auto pm = playlist_manager::get();
        t_size index = pm->get_playing_playlist();
        pfc::string8 name;
        if (index != pfc::infinite_size && pm->playlist_get_name(index, name)) {
            foobarName = [NSString stringWithUTF8String:name.c_str()];
        }
    }

    NSUInteger generation = [TreeModel shared].migrationGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([TreeModel shared].migrationGeneration != generation) return;
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"PlorgPlayingPlaylistChanged"
                          object:nil
                        userInfo:foobarName ? @{@"foobarName": foobarName} : nil];
    });
}

class plorg_play_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track | flag_on_playback_stop;
    }

    void on_playback_new_track(metadb_handle_ptr) override {
        @try {
            postPlayingPlaylistChanged(true);
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Exception in on_playback_new_track";
        }
    }

    void on_playback_stop(play_control::t_stop_reason reason) override {
        // Track changes and app shutdown also send a stop; keep the marker for those.
        if (reason == play_control::stop_reason_starting_another ||
            reason == play_control::stop_reason_shutting_down) return;
        @try {
            postPlayingPlaylistChanged(false);
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Exception in on_playback_stop";
        }
    }

    // Unused callbacks - required by interface
    void on_playback_starting(play_control::t_track_command, bool) override {}
    void on_playback_seek(double) override {}
    void on_playback_pause(bool) override {}
    void on_playback_edited(metadb_handle_ptr) override {}
    void on_playback_dynamic_info(const file_info&) override {}
    void on_playback_dynamic_info_track(const file_info&) override {}
    void on_playback_time(double) override {}
    void on_volume_change(float) override {}
};

FB2K_SERVICE_FACTORY(plorg_play_callback);

class plorg_playlist_callback : public playlist_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playlist_created |
               flag_on_playlist_renamed |
               flag_on_playlists_removed;
    }

    void on_playlist_created(t_size p_index, const char* p_name, t_size p_name_len) override {
        @try {
            NSString *name = [[NSString alloc] initWithBytes:p_name
                                                      length:p_name_len
                                                    encoding:NSUTF8StringEncoding];
            if (!name) return;

            std::string unusedPreviousName;
            rememberPlaylistName(p_index, name.UTF8String, unusedPreviousName);

            NSUInteger generation = [TreeModel shared].migrationGeneration;
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([TreeModel shared].migrationGeneration != generation) return;
                [[TreeModel shared] handlePlaylistCreated:name];
            });
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Exception in on_playlist_created";
        }
    }

    void on_playlist_renamed(t_size p_index, const char* p_new_name, t_size p_new_name_len) override {
        @try {
            NSString *newName = [[NSString alloc] initWithBytes:p_new_name
                                                         length:p_new_name_len
                                                       encoding:NSUTF8StringEncoding];
            if (!newName) return;

            // Read the previous name and store the new one now. A deferred block
            // cannot do it: p_index can point at another playlist by then (a sync
            // loop may rename and remove playlists in the same pass).
            std::string previousNameStr;
            CachedName cached = rememberPlaylistName(p_index, newName.UTF8String, previousNameStr);

            // Renaming the playing playlist changes the name the tree matches on
            if (p_index == playlist_manager::get()->get_playing_playlist()) {
                postPlayingPlaylistChanged(playback_control::get()->is_playing());
            }

            // The organizer's own renames already match the tree
            if ([TreeModel shared].ownRenameInProgress) return;

            if (cached == CachedName::unknown) {
                FB2K_console_formatter() << "[Plorg] Rename not followed, previous name unknown: "
                                          << [newName UTF8String];
            }
            if (cached != CachedName::known) return;

            NSString *previousName = [NSString stringWithUTF8String:previousNameStr.c_str()];
            if (!previousName || [previousName isEqualToString:newName]) return;

            NSUInteger generation = [TreeModel shared].migrationGeneration;
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([TreeModel shared].migrationGeneration != generation) return;
                [[TreeModel shared] handlePlaylistRenamed:previousName to:newName];
            });
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Exception in on_playlist_renamed";
        }
    }

    void on_playlists_removed(const pfc::bit_array& p_mask, t_size p_old_count, t_size p_new_count) override {
        @try {
            dispatch_async(dispatch_get_main_queue(), ^{
                FB2K_console_formatter() << "[Plorg] Playlists removed, count changed from "
                    << p_old_count << " to " << p_new_count;
            });
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Exception in on_playlists_removed";
        }
    }

    // Unused callbacks - required by interface
    void on_playlist_activate(t_size, t_size) override {}
    void on_items_added(t_size, t_size, const pfc::list_base_const_t<metadb_handle_ptr>&, const pfc::bit_array&) override {}
    void on_items_reordered(t_size, const t_size*, t_size) override {}
    void on_items_removing(t_size, const pfc::bit_array&, t_size, t_size) override {}
    void on_items_removed(t_size, const pfc::bit_array&, t_size, t_size) override {}
    void on_items_selection_change(t_size, const pfc::bit_array&, const pfc::bit_array&) override {}
    void on_item_focus_change(t_size, t_size, t_size) override {}
    void on_items_modified(t_size, const pfc::bit_array&) override {}
    void on_items_modified_fromplayback(t_size, const pfc::bit_array&, play_control::t_display_level) override {}
    void on_items_replaced(t_size, const pfc::bit_array&, const pfc::list_base_const_t<t_on_items_replaced_entry>&) override {}
    void on_item_ensure_visible(t_size, t_size) override {}
    void on_playlist_locked(t_size, bool) override {}
    void on_default_format_changed() override {}
    void on_playlists_removing(const pfc::bit_array&, t_size, t_size) override {}
    void on_playlists_reorder(const t_size*, t_size) override {}
    void on_playback_order_changed(t_size) override {}
};

FB2K_SERVICE_FACTORY(plorg_playlist_callback);

// Initialize on component load
class plorg_init : public initquit {
public:
    void on_init() override {
        [[TreeModel shared] loadFromConfig];
        [[TreeModel shared] repairCorruptedFoobarNames];
        // Here rather than on first use: inside a rename callback fb2k already
        // reports the new name, so the old one would be lost
        rebuildPlaylistNameCache();
        console::info("[Plorg] Playlist Organizer initialized");
    }

    void on_quit() override {
        [[TreeModel shared] saveToConfig];
    }
};

FB2K_SERVICE_FACTORY(plorg_init);

} // anonymous namespace
