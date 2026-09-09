//
//  LibraryCallbacks.mm
//  foo_jl_libvanced
//

#import "LibraryCallbacks.h"
#import "../UI/LibVancedController.h"
#import <mutex>

static std::mutex g_controllersMutex;
static NSHashTable<LibVancedController *> *g_controllers;

LibVancedCallbackManager& LibVancedCallbackManager::instance() {
    static LibVancedCallbackManager manager;
    return manager;
}

void LibVancedCallbackManager::registerController(LibVancedController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    if (!g_controllers) {
        g_controllers = [NSHashTable weakObjectsHashTable];
    }
    [g_controllers addObject:controller];
}

void LibVancedCallbackManager::unregisterController(LibVancedController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);
    [g_controllers removeObject:controller];
}

void LibVancedCallbackManager::onLibraryItemsAdded(metadb_handle_list_cref items) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (LibVancedController *c in g_controllers) {
            [c handleLibraryItemsAdded];
        }
    });
}

void LibVancedCallbackManager::onLibraryItemsRemoved(metadb_handle_list_cref items) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (LibVancedController *c in g_controllers) {
            [c handleLibraryItemsRemoved];
        }
    });
}

void LibVancedCallbackManager::onLibraryItemsModified(metadb_handle_list_cref items) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (LibVancedController *c in g_controllers) {
            [c handleLibraryItemsModified];
        }
    });
}

void LibVancedCallbackManager::onPlaybackNewTrack(metadb_handle_ptr track) {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (LibVancedController *c in g_controllers) {
            [c handlePlaybackNewTrack:track];
        }
    });
}

void LibVancedCallbackManager::onPlaybackStopped() {
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);
        for (LibVancedController *c in g_controllers) {
            [c handlePlaybackStopped];
        }
    });
}

// Convenience functions
void LibVancedCallbackManager_registerController(LibVancedController* controller) {
    LibVancedCallbackManager::instance().registerController(controller);
}

void LibVancedCallbackManager_unregisterController(LibVancedController* controller) {
    LibVancedCallbackManager::instance().unregisterController(controller);
}

// Library callback implementation
class libvanced_library_callback : public library_callback {
public:
    void on_items_added(metadb_handle_list_cref items) override {
        LibVancedCallbackManager::instance().onLibraryItemsAdded(items);
    }

    void on_items_removed(metadb_handle_list_cref items) override {
        LibVancedCallbackManager::instance().onLibraryItemsRemoved(items);
    }

    void on_items_modified(metadb_handle_list_cref items) override {
        LibVancedCallbackManager::instance().onLibraryItemsModified(items);
    }
};

FB2K_SERVICE_FACTORY(libvanced_library_callback);

// Playback callback implementation
class libvanced_playback_callback : public play_callback_static {
public:
    unsigned get_flags() override {
        return flag_on_playback_new_track | flag_on_playback_stop;
    }

    void on_playback_new_track(metadb_handle_ptr track) override {
        LibVancedCallbackManager::instance().onPlaybackNewTrack(track);
    }

    void on_playback_stop(play_control::t_stop_reason reason) override {
        LibVancedCallbackManager::instance().onPlaybackStopped();
    }

    void on_playback_starting(play_control::t_track_command cmd, bool paused) override {}
    void on_playback_seek(double time) override {}
    void on_playback_pause(bool paused) override {}
    void on_playback_edited(metadb_handle_ptr track) override {}
    void on_playback_dynamic_info(const file_info& info) override {}
    void on_playback_dynamic_info_track(const file_info& info) override {}
    void on_playback_time(double time) override {}
    void on_volume_change(float newVal) override {}
};

FB2K_SERVICE_FACTORY(libvanced_playback_callback);

// Init/quit callbacks are managed from Main.mm
void LibVancedCallbackManager::initCallbacks() {
    // Static library_callback and play_callback are auto-registered via FB2K_SERVICE_FACTORY
}

void LibVancedCallbackManager::shutdownCallbacks() {
    // Nothing to clean up - static callbacks are managed by the SDK
}
