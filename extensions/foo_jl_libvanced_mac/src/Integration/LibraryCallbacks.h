//
//  LibraryCallbacks.h
//  foo_jl_libvanced
//
//  Callback handlers for library and playback events
//

#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

@class LibVancedController;

class LibVancedCallbackManager {
public:
    static LibVancedCallbackManager& instance();

    void registerController(LibVancedController* controller);
    void unregisterController(LibVancedController* controller);

    // Library event dispatch
    void onLibraryItemsAdded(metadb_handle_list_cref items);
    void onLibraryItemsRemoved(metadb_handle_list_cref items);
    void onLibraryItemsModified(metadb_handle_list_cref items);

    // Playback event dispatch
    void onPlaybackNewTrack(metadb_handle_ptr track);
    void onPlaybackStopped();

    // Lifecycle
    void initCallbacks();
    void shutdownCallbacks();

private:
    LibVancedCallbackManager() = default;
};

void LibVancedCallbackManager_registerController(LibVancedController* controller);
void LibVancedCallbackManager_unregisterController(LibVancedController* controller);
