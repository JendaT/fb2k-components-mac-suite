//
//  TidalPrefetch.mm
//  foo_jl_tidal_mac
//
//  Warms JLTidalDashCache ahead of playback. When a track starts, resolve
//  and pre-assemble the track that plays after it (the queue head, else the
//  next entry in the playing playlist) so that when fb2k opens it, its DASH
//  blob is already in memory.
//

#include "../fb2k_sdk.h"
#import "../Core/URLUtils.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalModels.h"
#import "../Services/TidalStreamResolver.h"
#import "TidalDashCache.h"

namespace {

// Every reason the prefetch can decline is logged (debug). It used to return
// silently from each of them, so a prefetch that never ran looked exactly like
// one that ran and missed, and the only symptom was a gap before the next track.
static void logSkip(const char *reason) {
    tidal::logDebug((std::string("Prefetch skipped: ") + reason).c_str());
}

// The track fb2k will play after `current`, or an empty handle.
//
// The playback queue wins: whatever is queued plays next regardless of the
// playlist. Otherwise it is the playlist entry after the playing one. The
// SDK's own lookup for that position gives up whenever the playing item has
// left the playlist it started from, so fall back to finding the handle in
// the playing playlist (first occurrence; a duplicate entry may pick the
// wrong neighbour, which only costs a cache miss).
static metadb_handle_ptr nextTrackAfter(const metadb_handle_ptr &current) {
    auto pm = playlist_manager::get();

    if (pm->queue_get_count() > 0) {
        pfc::list_t<t_playback_queue_item> queue;
        pm->queue_get_contents(queue);
        if (queue.get_count() > 0) return queue[0].m_handle;
    }

    t_size playlistIdx = pfc_infinite, itemIdx = pfc_infinite;
    if (!pm->get_playing_item_location(&playlistIdx, &itemIdx)) {
        playlistIdx = pm->get_playing_playlist();
        if (playlistIdx == pfc_infinite || playlistIdx >= pm->get_playlist_count()) {
            logSkip("no playing playlist");
            return metadb_handle_ptr();
        }
        if (current.is_empty() || !pm->playlist_find_item(playlistIdx, current, itemIdx)) {
            logSkip("playing track not found in the playing playlist");
            return metadb_handle_ptr();
        }
    }

    t_size nextIdx = itemIdx + 1;
    if (nextIdx >= pm->playlist_get_item_count(playlistIdx)) {
        logSkip("playing track is the last in its playlist");
        return metadb_handle_ptr();
    }
    return pm->playlist_get_item_handle(playlistIdx, nextIdx);
}

class TidalPrefetch : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track;
    }

    void on_playback_new_track(metadb_handle_ptr track) override {
        @autoreleasepool {
            // Proves the hook fires at all: no line here after a track starts
            // means fb2k never delivered the callback.
            tidal::logDebug("Prefetch: track started, looking up the next one");
            if (!tidal::TidalConfig::isDASHEnabled()) {
                logSkip("DASH disabled");
                return;
            }

            // Playlist calls can throw; this runs inside fb2k's callback
            // dispatch, where an escaping exception takes the host down.
            metadb_handle_ptr next;
            try {
                next = nextTrackAfter(track);
            } catch (const std::exception &e) {
                logSkip(e.what());
                return;
            }
            if (next.is_empty()) return;
            warm(next);
        }
    }

private:
    void warm(const metadb_handle_ptr &next) {
        auto parsed = tidal::parseURL(next->get_path());
        if (!parsed.has_value() || parsed->type != tidal::TidalContentType::Track) {
            logSkip("next track is not a Tidal track");
            return;
        }

        NSString *trackID = [NSString stringWithUTF8String:parsed->id.c_str()];

        // Resolve at the tier the ENTRY asks for, not the global
        // preference: a "?q=" pin must resolve the same stream the
        // decoder will later ask for.
        JLTidalQuality requested = parsed->quality
            ? *parsed->quality
            : tidal::TidalConfig::getPreferredQuality();

        // Resolve (cached playback info is fast) then warm the blob.
        [[JLTidalStreamResolver shared] resolveStreamForTrackID:trackID
                                                        quality:requested
                                                     completion:^(JLTidalPlaybackInfo *info, NSError *error) {
            if (!info) {
                tidal::logInfo([[NSString stringWithFormat:@"Prefetch of next track %@ failed: %@",
                                 trackID, error.localizedDescription ?: @"no playback info"] UTF8String]);
                return;
            }

            // Warm metadata too: the decoder blocks on this for up to
            // 8s before it can open the stream, so a cold metadata
            // cache stalls the very track-change the prefetch exists
            // to make seamless.
            [[JLTidalStreamResolver shared] getMetadataForTrackID:trackID
                                                       completion:^(JLTidalTrack *t, NSError *e) {}];

            if (info.dashSegmentCount > 0 && info.dashMediaTemplate.length > 0) {
                // Key on the RESOLVED quality, which is what the
                // decoder looks up. Keying on the requested tier made
                // the prefetch miss for every track Tidal answers at a
                // lower tier than asked.
                tidal::logDebug([[NSString stringWithFormat:
                                 @"Prefetching next track %@ at %@ (requested %@, %ld segments)",
                                 trackID, JLTidalQualityToString(info.quality),
                                 JLTidalQualityToString(requested),
                                 (long)info.dashSegmentCount] UTF8String]);
                [[JLTidalDashCache shared] prefetchTrackID:trackID
                                                   quality:info.quality
                                             mediaTemplate:info.dashMediaTemplate
                                              segmentCount:info.dashSegmentCount];
            }
        }];
    }

public:
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
