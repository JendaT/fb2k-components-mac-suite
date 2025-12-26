//
//  PlaylistCallbacks.mm
//  foo_plorg_mac
//

#include "PlaylistCallbacks.h"
#import "../Core/TreeModel.h"

namespace {

class plorg_playlist_callback : public playlist_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playlist_activate |
               flag_on_playlist_created |
               flag_on_playlist_renamed |
               flag_on_playlists_removed;
    }

    void on_playlist_created(t_size p_index, const char* p_name, t_size p_name_len) override {
        @try {
            NSString *name = [[NSString alloc] initWithBytes:p_name
                                                      length:p_name_len
                                                    encoding:NSUTF8StringEncoding];
            if (!name) return;

            dispatch_async(dispatch_get_main_queue(), ^{
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

            dispatch_async(dispatch_get_main_queue(), ^{
                FB2K_console_formatter() << "[Plorg] Playlist renamed to: " << [newName UTF8String];
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

    void on_playlist_activate(t_size p_old, t_size p_new) override {
        @try {
            if (p_new == pfc::infinite_size) return;

            auto pm = playlist_manager::get();
            pfc::string8 name;
            if (pm->playlist_get_name(p_new, name)) {
                NSString *playlistName = [NSString stringWithUTF8String:name.c_str()];

                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter]
                        postNotificationName:@"PlaylistActivated"
                                      object:nil
                                    userInfo:@{@"name": playlistName}];
                });
            }
        } @catch (...) {
            FB2K_console_formatter() << "[Plorg] Exception in on_playlist_activate";
        }
    }

    // Unused callbacks - required by interface
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
        console::info("[Plorg] Playlist Organizer initialized");
    }

    void on_quit() override {
        [[TreeModel shared] saveToConfig];
    }
};

FB2K_SERVICE_FACTORY(plorg_init);

} // anonymous namespace
