//
//  Main.mm
//  foo_jl_album_art_mac
//
//  Component registration and SDK integration
//

#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#include "../../../../shared/version.h"

#import "../UI/AlbumArtController.h"
#import "../Core/AlbumArtFetcher.h"

// Component version declaration with unified branding
JL_COMPONENT_ABOUT(
    "Album Art (Extended)",
    ALBUMART_VERSION,
    "Extended album art viewer for foobar2000 macOS\n\n"
    "Features:\n"
    "- Display front, back, disc, icon, and artist artwork\n"
    "- Right-click context menu to switch artwork type\n"
    "- Navigation arrows on hover\n"
    "- Per-instance configuration\n"
    "- Layout parameters: type, square, zoomable"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_album_art.component");

// UI Element service registration (embeddable view)
namespace {
    static const GUID g_guid_album_art_ext = {
        0x8B2F4A1E, 0x3C5D, 0x7E9F,
        {0xAB, 0xCD, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC}
    };

    class album_art_ext_ui_element : public ui_element_mac {
    public:
        service_ptr instantiate(service_ptr arg) override {
            @autoreleasepool {
                // Unwrap layout parameters
                NSDictionary<NSString*, NSString*>* params = nil;
                if (arg.is_valid()) {
                    id obj = fb2k::unwrapNSObject(arg);
                    if ([obj isKindOfClass:[NSDictionary class]]) {
                        params = (NSDictionary<NSString*, NSString*>*)obj;
                    }
                }

                AlbumArtController* controller = [[AlbumArtController alloc] initWithParameters:params];
                return fb2k::wrapNSObject(controller);
            }
        }

        // Layout editor recognizes components by name - support all variations
        bool match_name(const char* name) override {
            return strcmp(name, "Album Art (Extended)") == 0 ||
                   strcmp(name, "albumart_ext") == 0 ||
                   strcmp(name, "album_art_ext") == 0 ||
                   strcmp(name, "albumart-ext") == 0 ||
                   strcmp(name, "foo_jl_album_art") == 0 ||
                   strcmp(name, "jl_album_art") == 0 ||
                   strcmp(name, "jl_albumart") == 0;
        }

        fb2k::stringRef get_name() override {
            return fb2k::makeString("Album Art (Extended)");
        }

        GUID get_guid() override {
            return g_guid_album_art_ext;
        }
    };

    FB2K_SERVICE_FACTORY(album_art_ext_ui_element);
}

// play_callback_static implementation for album art updates
class album_art_play_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track |
               flag_on_playback_stop;
    }

    void on_playback_new_track(metadb_handle_ptr p_track) override {
        AlbumArtCallbackManager::instance().onPlaybackNewTrack(p_track);
    }

    void on_playback_stop(play_control::t_stop_reason p_reason) override {
        AlbumArtCallbackManager::instance().onPlaybackStop(p_reason);
    }

    // Unused callbacks
    void on_playback_starting(play_control::t_track_command p_command, bool p_paused) override {}
    void on_playback_seek(double p_time) override {}
    void on_playback_pause(bool p_state) override {}
    void on_playback_edited(metadb_handle_ptr p_track) override {}
    void on_playback_dynamic_info(const file_info& p_info) override {}
    void on_playback_dynamic_info_track(const file_info& p_info) override {}
    void on_playback_time(double p_time) override {}
    void on_volume_change(float p_new_val) override {}
};

FB2K_SERVICE_FACTORY(album_art_play_callback);

// playlist_callback_static implementation for selection changes
class album_art_playlist_callback : public playlist_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_items_selection_change |
               flag_on_playlist_activate;
    }

    void on_items_added(t_size p_playlist, t_size p_start, const pfc::list_base_const_t<metadb_handle_ptr>& p_data, const bit_array& p_selection) override {}
    void on_items_reordered(t_size p_playlist, const t_size* p_order, t_size p_count) override {}
    void on_items_removing(t_size p_playlist, const bit_array& p_mask, t_size p_old_count, t_size p_new_count) override {}
    void on_items_removed(t_size p_playlist, const bit_array& p_mask, t_size p_old_count, t_size p_new_count) override {}

    void on_items_selection_change(t_size p_playlist, const bit_array& p_affected, const bit_array& p_state) override {
        // Only react to changes in the active playlist
        auto pm = playlist_manager::get();
        if (pm.is_valid() && pm->get_active_playlist() == p_playlist) {
            AlbumArtCallbackManager::instance().onSelectionChanged();
        }
    }

    void on_item_focus_change(t_size p_playlist, t_size p_from, t_size p_to) override {}
    void on_items_modified(t_size p_playlist, const bit_array& p_mask) override {}
    void on_items_modified_fromplayback(t_size p_playlist, const bit_array& p_mask, play_control::t_display_level p_level) override {}
    void on_items_replaced(t_size p_playlist, const bit_array& p_mask, const pfc::list_base_const_t<t_on_items_replaced_entry>& p_data) override {}
    void on_item_ensure_visible(t_size p_playlist, t_size p_idx) override {}

    void on_playlist_activate(t_size p_old, t_size p_new) override {
        // When switching playlists, update artwork based on new playlist's selection
        AlbumArtCallbackManager::instance().onSelectionChanged();
    }

    void on_playlist_created(t_size p_index, const char* p_name, t_size p_name_len) override {}
    void on_playlists_reorder(const t_size* p_order, t_size p_count) override {}
    void on_playlists_removing(const bit_array& p_mask, t_size p_old_count, t_size p_new_count) override {}
    void on_playlists_removed(const bit_array& p_mask, t_size p_old_count, t_size p_new_count) override {}
    void on_playlist_renamed(t_size p_index, const char* p_new_name, t_size p_new_name_len) override {}
    void on_default_format_changed() override {}
    void on_playback_order_changed(t_size p_new_index) override {}
    void on_playlist_locked(t_size p_playlist, bool p_locked) override {}
};

FB2K_SERVICE_FACTORY(album_art_playlist_callback);

// Initialize component on startup
class album_art_init : public initquit {
public:
    void on_init() override {
        console::info("[AlbumArt] Album Art (Extended) initialized");
    }

    void on_quit() override {
        // Cleanup if needed
    }
};

FB2K_SERVICE_FACTORY(album_art_init);
