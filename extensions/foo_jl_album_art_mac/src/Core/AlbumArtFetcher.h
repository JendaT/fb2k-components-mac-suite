//
//  AlbumArtFetcher.h
//  foo_jl_album_art_mac
//
//  Album art fetching and caching for currently playing track
//

#pragma once

#include "../fb2k_sdk.h"
#include "AlbumArtConfig.h"
#include <vector>
#include <mutex>

#ifdef __OBJC__
@class AlbumArtController;
#endif

// Callback manager for album art controllers
// Tracks both selected track (from playlist) and playing track
// Priority: selected track > playing track
class AlbumArtCallbackManager {
public:
    static AlbumArtCallbackManager& instance();

#ifdef __OBJC__
    void registerController(AlbumArtController* controller);
    void unregisterController(AlbumArtController* controller);
#endif

    // Playback callbacks
    void onPlaybackNewTrack(metadb_handle_ptr track);
    void onPlaybackStop(play_control::t_stop_reason reason);

    // Selection callbacks
    void onSelectionChanged();

    // Get current track handle (selected if available, else playing)
    metadb_handle_ptr getCurrentTrack() const;

    // Get the selected track from active playlist (first selected item)
    metadb_handle_ptr getSelectedTrack() const;

private:
    AlbumArtCallbackManager() = default;
    metadb_handle_ptr m_playingTrack;
    mutable std::mutex m_trackMutex;
};

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

// Album art fetcher utility class
@interface AlbumArtFetcher : NSObject

// Fetch album art for a track and type
// Returns NSImage or nil if not found
// This method should be called on a background thread for non-blocking behavior
+ (NSImage*)fetchArtworkForTrack:(metadb_handle_ptr)track
                            type:(albumart_config::ArtworkType)type;

// Check which artwork types are available for a track
// Returns array of NSNumber containing available ArtworkType values
+ (NSArray<NSNumber*>*)availableTypesForTrack:(metadb_handle_ptr)track;

// Convert album_art_data to NSImage
+ (NSImage*)imageFromAlbumArtData:(const album_art_data_ptr&)data;

@end

#endif // __OBJC__
