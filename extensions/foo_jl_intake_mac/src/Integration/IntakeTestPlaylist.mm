//
//  IntakeTestPlaylist.mm
//  foo_jl_intake
//
//  Hidden one-shot helper for in-app acceptance runs against the mock CLI
//  (docs/hidden-options.md, foo_jl_intake.test_playlist). Nobody can click
//  through foobar2000 during those runs, so the component builds and removes
//  its own test playlist when a config switch asks it to:
//
//    1  build: replace every playlist named "JL intake test" with a fresh one
//       holding the audio files under foo_jl_intake.test_playlist_dir, and
//       make it active;
//    2  remove: delete every playlist named "JL intake test".
//
//  The switch is reset to 0 after it acts. Only playlists with that exact
//  name are created or removed; other playlists are never touched. The folder
//  must be a local absolute path: anything under /Volumes or /volume1 is
//  refused, so this can never read a network share.
//
//  Temporary: removed with the other acceptance aids before the merge to
//  main.
//

#import "../fb2k_sdk.h"

#import <Foundation/Foundation.h>

#include "../Core/IntakeLog.h"

#include <algorithm>
#include <string>
#include <vector>

namespace {

const char *const kSwitchKey = "foo_jl_intake.test_playlist";
const char *const kDirKey = "foo_jl_intake.test_playlist_dir";
const char *const kPlaylistName = "JL intake test";
constexpr size_t kMaxFiles = 2000;

bool startsWith(const std::string &s, const char *prefix) {
    return s.rfind(prefix, 0) == 0;
}

// Empty string when acceptable, otherwise the reason it is refused.
std::string refusalFor(const std::string &dir) {
    if (dir.empty()) return "foo_jl_intake.test_playlist_dir is empty";
    if (dir[0] != '/') return "test_playlist_dir must be an absolute path";
    if (dir.find("/../") != std::string::npos || (dir.size() >= 3 && dir.compare(dir.size() - 3, 3, "/..") == 0)) {
        return "test_playlist_dir must not contain '..'";
    }
    if (startsWith(dir, "/Volumes/") || dir == "/Volumes" || startsWith(dir, "/volume1")) {
        return "test_playlist_dir must be local, not under /Volumes or /volume1";
    }
    return {};
}

size_t removeTestPlaylists(playlist_manager::ptr pm) {
    size_t removed = 0;
    for (t_size i = pm->get_playlist_count(); i-- > 0;) {
        pfc::string8 name;
        if (pm->playlist_get_name(i, name) && strcmp(name.c_str(), kPlaylistName) == 0) {
            if (pm->remove_playlist(i)) ++removed;
        }
    }
    return removed;
}

std::vector<std::string> audioFilesUnder(const std::string &dir) {
    std::vector<std::string> files;
    NSString *root = [NSString stringWithUTF8String:dir.c_str()];
    NSDirectoryEnumerator<NSString *> *walker = [[NSFileManager defaultManager] enumeratorAtPath:root];
    NSSet<NSString *> *extensions = [NSSet setWithArray:@[ @"wav", @"flac", @"mp3" ]];
    for (NSString *relative in walker) {
        if (![extensions containsObject:relative.pathExtension.lowercaseString]) continue;
        NSString *full = [root stringByAppendingPathComponent:relative];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;
        files.emplace_back(full.fileSystemRepresentation);
        if (files.size() >= kMaxFiles) break;
    }
    std::sort(files.begin(), files.end());
    return files;
}

void buildTestPlaylist(const std::string &dir) {
    const std::string refusal = refusalFor(dir);
    if (!refusal.empty()) {
        intake::logError(("test playlist not built: " + refusal).c_str());
        return;
    }
    const std::vector<std::string> files = audioFilesUnder(dir);
    if (files.empty()) {
        intake::logError(("test playlist not built: no .wav/.flac/.mp3 under " + dir).c_str());
        return;
    }

    auto pm = playlist_manager::get();
    const size_t removed = removeTestPlaylists(pm);
    const t_size index = pm->create_playlist(kPlaylistName, SIZE_MAX, SIZE_MAX);
    if (index == SIZE_MAX) {
        intake::logError("test playlist not built: create_playlist failed");
        return;
    }

    auto db = metadb::get();
    metadb_handle_list items;
    for (const std::string &path : files) {
        items.add_item(db->handle_create(("file://" + path).c_str(), 0));
    }
    pm->playlist_add_items(index, items, pfc::bit_array_false());
    pm->set_active_playlist(index);

    char line[256];
    snprintf(line, sizeof(line), "test playlist \"%s\" built with %zu files (replaced %zu)", kPlaylistName,
             files.size(), removed);
    intake::logInfo(line);

    // Handles made here carry no info, and SimPlaylist does not read tags
    // for displayed rows, so %album% would stay empty and every row would
    // fall into one group with no header (no badge to see). Read them in the
    // background, no dialog.
    const size_t count = files.size();
    metadb_io_v2::get()->load_info_async(
        items, metadb_io::load_info_default, core_api::get_main_window(),
        metadb_io_v2::op_flag_background | metadb_io_v2::op_flag_delay_ui | metadb_io_v2::op_flag_no_errors,
        fb2k::makeCompletionNotify([count](unsigned code) {
            char done[160];
            snprintf(done, sizeof(done), "test playlist: tags read for %zu files (%s)", count,
                     code == metadb_io::load_info_success   ? "success"
                     : code == metadb_io::load_info_aborted ? "aborted"
                                                            : "errors");
            intake::logInfo(done);
        }));
}

class intake_test_playlist_initquit : public initquit {
public:
    void on_init() override {
        const int64_t mode = fb2k::configStore::get()->getConfigInt(kSwitchKey, 0);
        if (mode != 1 && mode != 2) return;
        // After the loader's first run has had time to start, on the main
        // thread like every playlist_manager call.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (core_api::is_shutting_down()) return;
                           auto store = fb2k::configStore::get();
                           store->setConfigInt(kSwitchKey, 0);
                           if (mode == 1) {
                               buildTestPlaylist(store->getConfigString(kDirKey)->c_str());
                           } else {
                               const size_t removed = removeTestPlaylists(playlist_manager::get());
                               char line[128];
                               snprintf(line, sizeof(line), "test playlist: removed %zu playlist(s) named \"%s\"",
                                        removed, kPlaylistName);
                               intake::logInfo(line);
                           }
                       });
    }
    void on_quit() override {}
};

FB2K_SERVICE_FACTORY(intake_test_playlist_initquit);

}  // namespace
