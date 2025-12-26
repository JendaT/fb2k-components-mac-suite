//
//  PlaylistCallbacks.h
//  foo_simplaylist_mac
//
//  Callback handlers for playlist and playback events
//

#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

@class SimPlaylistController;

// Callback manager for controller registration
class SimPlaylistCallbackManager {
public:
    static SimPlaylistCallbackManager& instance();

    void registerController(SimPlaylistController* controller);
    void unregisterController(SimPlaylistController* controller);

    // Playlist event dispatch
    void onPlaylistSwitched();
    void onItemsAdded(t_size base, t_size count);
    void onItemsRemoved();
    void onItemsReordered();
    void onSelectionChanged();
    void onFocusChanged(t_size from, t_size to);
    void onItemsModified();

    // Playback event dispatch
    void onPlaybackNewTrack(metadb_handle_ptr track);
    void onPlaybackStopped();

    // Lifecycle - call from initquit
    void initCallbacks();
    void shutdownCallbacks();

private:
    SimPlaylistCallbackManager() = default;
};

// Convenience functions
void SimPlaylistCallbackManager_registerController(SimPlaylistController* controller);
void SimPlaylistCallbackManager_unregisterController(SimPlaylistController* controller);
