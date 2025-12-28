//
//  AlbumArtFetcher.mm
//  foo_jl_album_art_mac
//
//  Album art fetching implementation
//

#import "AlbumArtFetcher.h"
#import "../UI/AlbumArtController.h"

// Registered controllers
static std::vector<__weak AlbumArtController*> g_controllers;
static std::mutex g_controllersMutex;

AlbumArtCallbackManager& AlbumArtCallbackManager::instance() {
    static AlbumArtCallbackManager manager;
    return manager;
}

void AlbumArtCallbackManager::registerController(AlbumArtController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);

    // Check if already registered
    for (const auto& weak : g_controllers) {
        if (weak == controller) return;
    }

    g_controllers.push_back(controller);
}

void AlbumArtCallbackManager::unregisterController(AlbumArtController* controller) {
    std::lock_guard<std::mutex> lock(g_controllersMutex);

    g_controllers.erase(
        std::remove_if(g_controllers.begin(), g_controllers.end(),
            [controller](const __weak AlbumArtController* weak) {
                return weak == nil || weak == controller;
            }),
        g_controllers.end()
    );
}

void AlbumArtCallbackManager::onPlaybackNewTrack(metadb_handle_ptr track) {
    {
        std::lock_guard<std::mutex> lock(m_trackMutex);
        m_playingTrack = track;
    }

    // Get the track to display (selected if available, else playing)
    metadb_handle_ptr displayTrack = getCurrentTrack();

    // Notify controllers on main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak AlbumArtController* weak : g_controllers) {
            AlbumArtController* controller = weak;
            if (controller) {
                [controller handleNewTrack:displayTrack];
            }
        }
    });
}

void AlbumArtCallbackManager::onPlaybackStop(play_control::t_stop_reason reason) {
    {
        std::lock_guard<std::mutex> lock(m_trackMutex);
        m_playingTrack.release();
    }

    // Check if there's a selected track to fall back to
    metadb_handle_ptr selectedTrack = getSelectedTrack();

    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak AlbumArtController* weak : g_controllers) {
            AlbumArtController* controller = weak;
            if (controller) {
                if (selectedTrack.is_valid()) {
                    [controller handleNewTrack:selectedTrack];
                } else {
                    [controller handlePlaybackStop];
                }
            }
        }
    });
}

void AlbumArtCallbackManager::onSelectionChanged() {
    // Get the track to display (selected if available, else playing)
    metadb_handle_ptr displayTrack = getCurrentTrack();

    dispatch_async(dispatch_get_main_queue(), ^{
        std::lock_guard<std::mutex> lock(g_controllersMutex);

        for (__weak AlbumArtController* weak : g_controllers) {
            AlbumArtController* controller = weak;
            if (controller) {
                if (displayTrack.is_valid()) {
                    [controller handleNewTrack:displayTrack];
                } else {
                    [controller handlePlaybackStop];
                }
            }
        }
    });
}

metadb_handle_ptr AlbumArtCallbackManager::getSelectedTrack() const {
    try {
        auto pm = playlist_manager::get();
        if (!pm.is_valid()) return metadb_handle_ptr();

        t_size activePlaylist = pm->get_active_playlist();
        if (activePlaylist == pfc::infinite_size) return metadb_handle_ptr();

        // Get selected items from active playlist
        metadb_handle_list selected;
        pm->playlist_get_selected_items(activePlaylist, selected);

        if (selected.get_count() > 0) {
            return selected[0];  // Return first selected item
        }
    } catch (...) {
        // Ignore errors
    }
    return metadb_handle_ptr();
}

metadb_handle_ptr AlbumArtCallbackManager::getCurrentTrack() const {
    // Priority: selected track > playing track
    metadb_handle_ptr selected = getSelectedTrack();
    if (selected.is_valid()) {
        return selected;
    }

    std::lock_guard<std::mutex> lock(m_trackMutex);
    return m_playingTrack;
}

@implementation AlbumArtFetcher

+ (NSImage*)fetchArtworkForTrack:(metadb_handle_ptr)track
                            type:(albumart_config::ArtworkType)type {
    if (!track.is_valid()) {
        return nil;
    }

    @autoreleasepool {
        try {
            abort_callback_dummy abort;
            GUID artGUID = albumart_config::artworkTypeToGUID(type);

            // Try to get album art using album_art_manager_v2
            auto manager = album_art_manager_v2::get();
            if (!manager.is_valid()) {
                return nil;
            }

            // Create list with single track
            metadb_handle_list tracks;
            tracks.add_item(track);

            // Create list with the requested art type
            pfc::list_t<GUID> ids;
            ids.add_item(artGUID);

            // Open album art extractor
            auto extractor = manager->open(tracks, ids, abort);
            if (!extractor.is_valid()) {
                return nil;
            }

            // Query for the artwork
            album_art_data_ptr data;
            if (!extractor->query(artGUID, data, abort)) {
                return nil;
            }

            return [self imageFromAlbumArtData:data];

        } catch (const exception_album_art_not_found&) {
            // Art not found - this is expected for some types
            return nil;
        } catch (const exception_album_art_unsupported_format&) {
            FB2K_console_formatter() << "[AlbumArt] Unsupported album art format";
            return nil;
        } catch (const std::exception& e) {
            FB2K_console_formatter() << "[AlbumArt] Error fetching artwork: " << e.what();
            return nil;
        } catch (...) {
            FB2K_console_formatter() << "[AlbumArt] Unknown error fetching artwork";
            return nil;
        }
    }
}

+ (NSArray<NSNumber*>*)availableTypesForTrack:(metadb_handle_ptr)track {
    if (!track.is_valid()) {
        return @[];
    }

    NSMutableArray<NSNumber*>* available = [NSMutableArray array];

    @autoreleasepool {
        try {
            abort_callback_dummy abort;

            // Try to get album art using album_art_manager_v2
            auto manager = album_art_manager_v2::get();
            if (!manager.is_valid()) {
                return @[];
            }

            // Create list with single track
            metadb_handle_list tracks;
            tracks.add_item(track);

            // Request all art types
            pfc::list_t<GUID> allIds;
            allIds.add_item(album_art_ids::cover_front);
            allIds.add_item(album_art_ids::cover_back);
            allIds.add_item(album_art_ids::disc);
            allIds.add_item(album_art_ids::icon);
            allIds.add_item(album_art_ids::artist);

            auto extractor = manager->open(tracks, allIds, abort);
            if (!extractor.is_valid()) {
                return @[];
            }

            // Check each type
            for (int i = 0; i < static_cast<int>(albumart_config::ArtworkType::Count); ++i) {
                auto type = static_cast<albumart_config::ArtworkType>(i);
                GUID guid = albumart_config::artworkTypeToGUID(type);

                if (extractor->have_entry(guid, abort)) {
                    [available addObject:@(i)];
                }
            }

        } catch (...) {
            // On any error, return empty array
        }
    }

    return [available copy];
}

+ (NSImage*)imageFromAlbumArtData:(const album_art_data_ptr&)data {
    if (!data.is_valid() || data->size() == 0) {
        return nil;
    }

    NSData* imageData = [NSData dataWithBytes:data->data() length:data->size()];
    if (!imageData) {
        return nil;
    }

    NSImage* image = [[NSImage alloc] initWithData:imageData];
    return image;
}

@end
