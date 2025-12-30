//
//  BiographyCallbackManager.mm
//  foo_jl_biography_mac
//
//  Callback manager implementation
//

#import "BiographyCallbackManager.h"
#import "../UI/BiographyController.h"
#include <vector>

// Registered controllers (weak references to avoid retain cycles)
static std::vector<__weak BiographyController*> g_controllers;
static std::mutex g_controllersMutex;

BiographyCallbackManager& BiographyCallbackManager::instance() {
    static BiographyCallbackManager manager;
    return manager;
}

void BiographyCallbackManager::registerController(BiographyController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);

    // Check if already registered
    for (const auto& weak : g_controllers) {
        if (weak == controller) return;
    }

    g_controllers.push_back(controller);
}

void BiographyCallbackManager::unregisterController(BiographyController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);

    g_controllers.erase(
        std::remove_if(g_controllers.begin(), g_controllers.end(),
            [controller](const __weak BiographyController* weak) {
                return weak == nil || weak == controller;
            }),
        g_controllers.end()
    );
}

void BiographyCallbackManager::onPlaybackNewTrack(metadb_handle_ptr track) {
    {
        std::lock_guard<std::mutex> lock(m_trackMutex);
        m_playingTrack = track;
    }

    // Get the track to display (selected if available, else playing)
    metadb_handle_ptr displayTrack = getCurrentTrack();
    std::string artist = extractArtistFromTrack(displayTrack);

    // Notify controllers on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        NSString* artistName = artist.empty() ? nil : [NSString stringWithUTF8String:artist.c_str()];

        for (__weak BiographyController* weak : g_controllers) {
            BiographyController* controller = weak;
            if (controller) {
                [controller handleArtistChange:artistName];
            }
        }
    });
}

void BiographyCallbackManager::onPlaybackStop(play_control::t_stop_reason reason) {
    {
        std::lock_guard<std::mutex> lock(m_trackMutex);
        m_playingTrack.release();
    }

    // Check if there's a selected track to fall back to
    metadb_handle_ptr selectedTrack = getSelectedTrack();
    std::string artist = extractArtistFromTrack(selectedTrack);

    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak BiographyController* weak : g_controllers) {
            BiographyController* controller = weak;
            if (controller) {
                if (!artist.empty()) {
                    NSString* artistName = [NSString stringWithUTF8String:artist.c_str()];
                    [controller handleArtistChange:artistName];
                } else {
                    [controller handlePlaybackStop];
                }
            }
        }
    });
}

void BiographyCallbackManager::onSelectionChanged() {
    // Get the track to display (selected if available, else playing)
    metadb_handle_ptr displayTrack = getCurrentTrack();
    std::string artist = extractArtistFromTrack(displayTrack);

    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak BiographyController* weak : g_controllers) {
            BiographyController* controller = weak;
            if (controller) {
                if (!artist.empty()) {
                    NSString* artistName = [NSString stringWithUTF8String:artist.c_str()];
                    [controller handleArtistChange:artistName];
                } else {
                    [controller handlePlaybackStop];
                }
            }
        }
    });
}

metadb_handle_ptr BiographyCallbackManager::getCurrentTrack() const {
    // First try selected track
    metadb_handle_ptr selected = getSelectedTrack();
    if (selected.is_valid()) {
        return selected;
    }

    // Fall back to playing track
    std::lock_guard<std::mutex> lock(m_trackMutex);
    return m_playingTrack;
}

metadb_handle_ptr BiographyCallbackManager::getSelectedTrack() const {
    auto pm = playlist_manager::get();
    if (!pm.is_valid()) return nullptr;

    t_size activePlaylist = pm->get_active_playlist();
    if (activePlaylist == pfc::infinite_size) return nullptr;

    t_size focusedItem = pm->playlist_get_focus_item(activePlaylist);
    if (focusedItem == pfc::infinite_size) return nullptr;

    // Get the focused item if it's selected
    bit_array_bittable selection(pm->playlist_get_item_count(activePlaylist));
    pm->playlist_get_selection_mask(activePlaylist, selection);

    if (!selection.get(focusedItem)) {
        // Focus not selected, try to find first selected
        t_size count = pm->playlist_get_item_count(activePlaylist);
        for (t_size i = 0; i < count; i++) {
            if (selection.get(i)) {
                focusedItem = i;
                break;
            }
        }
    }

    if (selection.get(focusedItem)) {
        metadb_handle_ptr track;
        pm->playlist_get_item_handle(track, activePlaylist, focusedItem);
        return track;
    }

    return nullptr;
}

std::string BiographyCallbackManager::extractArtistFromTrack(metadb_handle_ptr track) {
    if (!track.is_valid()) return "";

    pfc::string8 artist;

    // Try to get the artist field
    const file_info* info = nullptr;
    metadb_info_container::ptr infoPtr;

    if (track->get_info_ref(infoPtr) && infoPtr.is_valid()) {
        info = &infoPtr->info();

        // Try ARTIST field first
        const char* artistValue = info->meta_get("ARTIST", 0);
        if (artistValue && artistValue[0] != '\0') {
            return std::string(artistValue);
        }

        // Try ALBUM ARTIST as fallback
        artistValue = info->meta_get("ALBUM ARTIST", 0);
        if (artistValue && artistValue[0] != '\0') {
            return std::string(artistValue);
        }

        // Try ALBUMARTIST (single word variant)
        artistValue = info->meta_get("ALBUMARTIST", 0);
        if (artistValue && artistValue[0] != '\0') {
            return std::string(artistValue);
        }

        // Try PERFORMER as last resort
        artistValue = info->meta_get("PERFORMER", 0);
        if (artistValue && artistValue[0] != '\0') {
            return std::string(artistValue);
        }
    }

    return "";
}
