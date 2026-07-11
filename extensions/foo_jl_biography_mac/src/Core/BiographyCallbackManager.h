//
//  BiographyCallbackManager.h
//  foo_jl_biography_mac
//
//  Callback manager for biography controllers - handles track change notifications
//

#pragma once

#include "../fb2k_sdk.h"
#include <mutex>

#ifdef __OBJC__
/// Protocol for objects that want to receive artist change notifications (ARCH-4)
@protocol BiographyArtistObserver <NSObject>
- (void)handleArtistChange:(NSString * _Nullable)artistName;
- (void)handlePlaybackStop;
@end
#endif

/// Singleton callback manager that tracks registered biography controllers
/// and notifies them of track changes. Thread-safe.
class BiographyCallbackManager {
public:
    static BiographyCallbackManager& instance();

#ifdef __OBJC__
    /// Register an observer to receive track change notifications
    void registerController(id<BiographyArtistObserver> controller);

    /// Unregister an observer when it's being deallocated
    void unregisterController(id<BiographyArtistObserver> controller);
#endif

    // Playback callbacks (called from C++ play_callback)
    void onPlaybackNewTrack(metadb_handle_ptr track);
    void onPlaybackStop(play_control::t_stop_reason reason);

    // Selection callback (called from C++ playlist_callback)
    void onSelectionChanged();

    /// Get current track handle (selected if available, else playing)
    metadb_handle_ptr getCurrentTrack() const;

    /// Get the selected track from active playlist (first selected item)
    metadb_handle_ptr getSelectedTrack() const;

    /// Extract artist name from a track's metadata
    /// Returns empty string if no artist metadata found
    static std::string extractArtistFromTrack(metadb_handle_ptr track);

private:
    BiographyCallbackManager() = default;
    metadb_handle_ptr m_playingTrack;
    mutable std::mutex m_trackMutex;
};
