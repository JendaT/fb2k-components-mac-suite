//
//  TidalPrefetch.mm
//  foo_jl_tidal_mac
//
//  Warms JLTidalDashCache ahead of playback. When a track starts, resolve
//  and pre-assemble the next tidal:// track(s) in the active playlist so
//  that when fb2k opens them, their DASH blob is already in memory.
//

#include "../fb2k_sdk.h"
#import "../Core/URLUtils.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalModels.h"
#import "../Services/TidalStreamResolver.h"
#import "TidalDashCache.h"

namespace {

// How many upcoming tracks to warm. 1 covers sequential album/playlist
// playthrough (the common case) at a modest memory/bandwidth cost; the
// first track a user picks is never prefetched (nothing precedes it).
// Shuffle/repeat orderings are not modelled — this walks the playlist in
// index order, so a shuffled next track simply misses the cache.
static const int kPrefetchDepth = 1;

class TidalPrefetch : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track;
    }

    void on_playback_new_track(metadb_handle_ptr track) override {
        @autoreleasepool {
            if (!tidal::TidalConfig::isDASHEnabled()) return;

            auto pm = playlist_manager::get();
            t_size playlistIdx = 0, itemIdx = 0;
            if (!pm->get_playing_item_location(&playlistIdx, &itemIdx)) return;

            t_size count = pm->playlist_get_item_count(playlistIdx);
            for (int k = 1; k <= kPrefetchDepth; k++) {
                t_size nextIdx = itemIdx + (t_size)k;
                if (nextIdx >= count) break;

                metadb_handle_ptr next = pm->playlist_get_item_handle(playlistIdx, nextIdx);
                if (next.is_empty()) continue;

                auto parsed = tidal::parseURL(next->get_path());
                if (!parsed.has_value() || parsed->type != tidal::TidalContentType::Track) continue;

                NSString *trackID = [NSString stringWithUTF8String:parsed->id.c_str()];
                if ([[JLTidalDashCache shared] cachedBlobForTrackID:trackID]) continue;

                // Resolve (cached playback info is fast) then warm the blob.
                [[JLTidalStreamResolver shared] resolveStreamForTrackID:trackID
                                                             completion:^(JLTidalPlaybackInfo *info, NSError *error) {
                    if (!info) return;
                    if (info.dashSegmentCount > 0 && info.dashMediaTemplate.length > 0) {
                        tidal::logDebug([[NSString stringWithFormat:@"Prefetching next track %@ (%ld segments)",
                                          trackID, (long)info.dashSegmentCount] UTF8String]);
                        [[JLTidalDashCache shared] prefetchTrackID:trackID
                                                     mediaTemplate:info.dashMediaTemplate
                                                      segmentCount:info.dashSegmentCount];
                    }
                }];
            }
        }
    }

    // Unused callbacks
    void on_playback_starting(play_control::t_track_command, bool) override {}
    void on_playback_stop(play_control::t_stop_reason) override {}
    void on_playback_seek(double) override {}
    void on_playback_pause(bool) override {}
    void on_playback_edited(metadb_handle_ptr) override {}
    void on_playback_dynamic_info(const file_info &) override {}
    void on_playback_dynamic_info_track(const file_info &) override {}
    void on_playback_time(double) override {}
    void on_volume_change(float) override {}
};

FB2K_SERVICE_FACTORY(TidalPrefetch);

} // anonymous namespace
