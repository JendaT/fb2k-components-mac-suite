//
//  TidalSaveMenu.mm
//  foo_jl_tidal_mac
//
//  Playlist context-menu commands "Save to library (music.hq)" and "Save to
//  folder...". Personal feature: hidden unless the tidal.TI_download_on gate
//  is set in the fb2k config store (docs/hidden-options.md) and the
//  selection contains at least one tidal:// track. The library command also
//  needs a library root configured in preferences; the folder command asks
//  for a destination instead, for when the music.hq layout is not where the
//  album belongs. Hands the selected track IDs to JLTidalLibrarySaver, which
//  runs in the background.
//

#include "../fb2k_sdk.h"
#import <AppKit/AppKit.h>
#import "../Core/TidalConfig.h"
#import "../Core/URLUtils.h"
#import "TidalLibrarySaver.h"

namespace {

// {D4B7A1C2-9E35-4F6B-8A21-3C5D7E90F412}
static const GUID g_saveToLibraryGUID =
    { 0xd4b7a1c2, 0x9e35, 0x4f6b, { 0x8a, 0x21, 0x3c, 0x5d, 0x7e, 0x90, 0xf4, 0x12 } };
// {6E2F9B14-7C3A-4D85-B1E0-5A8C2F4D9E37}
static const GUID g_saveToFolderGUID =
    { 0x6e2f9b14, 0x7c3a, 0x4d85, { 0xb1, 0xe0, 0x5a, 0x8c, 0x2f, 0x4d, 0x9e, 0x37 } };

enum : unsigned { kItemLibrary = 0, kItemFolder = 1, kItemCount = 2 };

// Asks where to save. Opens at the last folder used, else the library root.
// nil when cancelled.
static NSString *chooseDestinationFolder(NSUInteger trackCount) {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Save Here";
    panel.message = trackCount == 1
        ? @"Choose the folder to save the track's album folder into"
        : [NSString stringWithFormat:@"Choose the folder to save the album folders of %lu tracks into",
           (unsigned long)trackCount];

    std::string start = tidal::TidalConfig::getLastSaveFolder();
    if (start.empty()) start = tidal::TidalConfig::getLibraryRoot();
    if (!start.empty()) {
        panel.directoryURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:start.c_str()]
                                        isDirectory:YES];
    }

    if ([panel runModal] != NSModalResponseOK || panel.URL.path.length == 0) return nil;
    NSString *folder = panel.URL.path;
    tidal::TidalConfig::setLastSaveFolder(std::string(folder.UTF8String));
    return folder;
}

// Returns the selection as "<trackID>" or "<trackID>|<QUALITY>" so a pinned
// entry exports at the tier it plays at, not at whatever the preference
// happens to be. Dedupe is on the pair: the same track pinned twice is two
// different files, and collapsing them would export one and silently drop the
// other.
static NSArray<NSString *> *tidalTrackIDsFromSelection(metadb_handle_list_cref data) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (t_size i = 0; i < data.get_count(); i++) {
        metadb_handle_ptr item = data.get_item(i);
        if (item.is_empty()) continue;
        auto parsed = tidal::parseURL(item->get_path());
        if (!parsed.has_value() || parsed->type != tidal::TidalContentType::Track) continue;
        NSString *trackID = [NSString stringWithUTF8String:parsed->id.c_str()];
        NSString *key = parsed->quality
            ? [NSString stringWithFormat:@"%@|%@", trackID, JLTidalQualityToString(*parsed->quality)]
            : trackID;
        if ([seen containsObject:key]) continue;
        [seen addObject:key];
        [ids addObject:key];
    }
    return ids;
}

class TidalSaveMenu : public contextmenu_item_simple {
public:
    unsigned get_num_items() override { return kItemCount; }

    void get_item_name(unsigned p_index, pfc::string_base &out) override {
        out = (p_index == kItemFolder) ? "Save to folder..." : "Save to library (music.hq)";
    }

    GUID get_item_guid(unsigned p_index) override {
        return (p_index == kItemFolder) ? g_saveToFolderGUID : g_saveToLibraryGUID;
    }

    bool get_item_description(unsigned p_index, pfc::string_base &out) override {
        if (p_index == kItemFolder) {
            out = "Downloads the selected TIDAL tracks into a folder you choose, "
                  "one \"Artist [YYYY] Album\" folder per album.";
        } else {
            out = "Downloads the selected TIDAL tracks into the configured library "
                  "folder using the music.hq genre/artist/release layout.";
        }
        return true;
    }

    GUID get_parent() override { return contextmenu_groups::root; }

    bool context_get_display(unsigned p_index, metadb_handle_list_cref p_data,
                             pfc::string_base &p_out, unsigned &p_displayflags,
                             const GUID &p_caller) override {
        if (!tidal::TidalConfig::isDownloadFeatureEnabled()) return false;
        // Only the library layout needs a root; the folder command asks.
        if (p_index == kItemLibrary && tidal::TidalConfig::getLibraryRoot().empty()) return false;

        @autoreleasepool {
            NSArray<NSString *> *ids = tidalTrackIDsFromSelection(p_data);
            if (ids.count == 0) return false;
            if (ids.count > 1) {
                p_out << "Save " << (unsigned)ids.count
                      << (p_index == kItemFolder ? " tracks to folder..." : " tracks to library (music.hq)");
            } else {
                get_item_name(p_index, p_out);
            }
        }
        return true;
    }

    void context_command(unsigned p_index, metadb_handle_list_cref p_data, const GUID &) override {
        @autoreleasepool {
            NSArray<NSString *> *ids = tidalTrackIDsFromSelection(p_data);
            if (ids.count == 0) return;
            if (p_index == kItemFolder) {
                NSString *folder = chooseDestinationFolder(ids.count);
                if (folder) [[JLTidalLibrarySaver shared] saveTrackIDs:ids toFolder:folder];
                return;
            }
            [[JLTidalLibrarySaver shared] saveTrackIDs:ids];
        }
    }
};

FB2K_SERVICE_FACTORY(TidalSaveMenu);

} // anonymous namespace
