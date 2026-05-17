#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

@class AlbumViewVancedController;

class AlbumViewVancedCallbackManager {
public:
    static AlbumViewVancedCallbackManager& instance();

    void registerController(AlbumViewVancedController* controller);
    void unregisterController(AlbumViewVancedController* controller);

    void onLibraryItemsAdded(metadb_handle_list_cref items);
    void onLibraryItemsRemoved(metadb_handle_list_cref items);
    void onLibraryItemsModified(metadb_handle_list_cref items);

private:
    AlbumViewVancedCallbackManager() = default;
};

void AlbumViewVancedCallbackManager_registerController(AlbumViewVancedController* controller);
void AlbumViewVancedCallbackManager_unregisterController(AlbumViewVancedController* controller);
