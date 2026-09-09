#import "AlbumViewVancedCallbacks.h"
#import "../UI/AlbumViewVancedController.h"
#import <mutex>

static std::mutex g_controllersMutex;
static NSHashTable<AlbumViewVancedController *> *g_controllers;

AlbumViewVancedCallbackManager& AlbumViewVancedCallbackManager::instance() {
    static AlbumViewVancedCallbackManager manager;
    return manager;
}

void AlbumViewVancedCallbackManager::registerController(AlbumViewVancedController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    if (!g_controllers) {
        g_controllers = [NSHashTable weakObjectsHashTable];
    }
    [g_controllers addObject:controller];
}

void AlbumViewVancedCallbackManager::unregisterController(AlbumViewVancedController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    [g_controllers removeObject:controller];
}

void AlbumViewVancedCallbackManager::onLibraryItemsAdded(metadb_handle_list_cref items) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (AlbumViewVancedController *c in g_controllers) {
            [c handleLibraryItemsAdded];
        }
    });
}

void AlbumViewVancedCallbackManager::onLibraryItemsRemoved(metadb_handle_list_cref items) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (AlbumViewVancedController *c in g_controllers) {
            [c handleLibraryItemsRemoved];
        }
    });
}

void AlbumViewVancedCallbackManager::onLibraryItemsModified(metadb_handle_list_cref items) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (AlbumViewVancedController *c in g_controllers) {
            [c handleLibraryItemsModified];
        }
    });
}

void AlbumViewVancedCallbackManager_registerController(AlbumViewVancedController* controller) {
    AlbumViewVancedCallbackManager::instance().registerController(controller);
}

void AlbumViewVancedCallbackManager_unregisterController(AlbumViewVancedController* controller) {
    AlbumViewVancedCallbackManager::instance().unregisterController(controller);
}

class albumviewvanced_library_callback : public library_callback {
public:
    void on_items_added(metadb_handle_list_cref items) override {
        AlbumViewVancedCallbackManager::instance().onLibraryItemsAdded(items);
    }
    void on_items_removed(metadb_handle_list_cref items) override {
        AlbumViewVancedCallbackManager::instance().onLibraryItemsRemoved(items);
    }
    void on_items_modified(metadb_handle_list_cref items) override {
        AlbumViewVancedCallbackManager::instance().onLibraryItemsModified(items);
    }
};

FB2K_SERVICE_FACTORY(albumviewvanced_library_callback);
