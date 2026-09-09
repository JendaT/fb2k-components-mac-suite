//
//  TidalSaveMenu.mm
//  foo_jl_tidal_mac
//
//  Playlist context-menu command "Save to library (music.hq)". Personal
//  feature: hidden unless a library root is configured in preferences and
//  the selection contains at least one tidal:// track. Hands the selected
//  track IDs to JLTidalLibrarySaver, which runs in the background.
//

#include "../fb2k_sdk.h"
#import "../Core/TidalConfig.h"
#import "../Core/URLUtils.h"
#import "TidalLibrarySaver.h"

namespace {

// {D4B7A1C2-9E35-4F6B-8A21-3C5D7E90F412}
static const GUID g_saveToLibraryGUID =
    { 0xd4b7a1c2, 0x9e35, 0x4f6b, { 0x8a, 0x21, 0x3c, 0x5d, 0x7e, 0x90, 0xf4, 0x12 } };

static NSArray<NSString *> *tidalTrackIDsFromSelection(metadb_handle_list_cref data) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (t_size i = 0; i < data.get_count(); i++) {
        metadb_handle_ptr item = data.get_item(i);
        if (item.is_empty()) continue;
        auto parsed = tidal::parseURL(item->get_path());
        if (!parsed.has_value() || parsed->type != tidal::TidalContentType::Track) continue;
        NSString *trackID = [NSString stringWithUTF8String:parsed->id.c_str()];
        if ([seen containsObject:trackID]) continue;
        [seen addObject:trackID];
        [ids addObject:trackID];
    }
    return ids;
}

class TidalSaveMenu : public contextmenu_item_simple {
public:
    unsigned get_num_items() override { return 1; }

    void get_item_name(unsigned, pfc::string_base &out) override {
        out = "Save to library (music.hq)";
    }

    GUID get_item_guid(unsigned) override { return g_saveToLibraryGUID; }

    bool get_item_description(unsigned, pfc::string_base &out) override {
        out = "Downloads the selected TIDAL tracks into the configured library "
              "folder using the music.hq genre/artist/release layout.";
        return true;
    }

    GUID get_parent() override { return contextmenu_groups::root; }

    bool context_get_display(unsigned p_index, metadb_handle_list_cref p_data,
                             pfc::string_base &p_out, unsigned &p_displayflags,
                             const GUID &p_caller) override {
        if (tidal::TidalConfig::getLibraryRoot().empty()) return false;

        @autoreleasepool {
            NSArray<NSString *> *ids = tidalTrackIDsFromSelection(p_data);
            if (ids.count == 0) return false;
            if (ids.count > 1) {
                p_out << "Save " << (unsigned)ids.count << " tracks to library (music.hq)";
            } else {
                get_item_name(p_index, p_out);
            }
        }
        return true;
    }

    void context_command(unsigned, metadb_handle_list_cref p_data, const GUID &) override {
        @autoreleasepool {
            NSArray<NSString *> *ids = tidalTrackIDsFromSelection(p_data);
            if (ids.count == 0) return;
            [[JLTidalLibrarySaver shared] saveTrackIDs:ids];
        }
    }
};

FB2K_SERVICE_FACTORY(TidalSaveMenu);

} // anonymous namespace
