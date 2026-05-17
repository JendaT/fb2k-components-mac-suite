//
//  QueueCallbackManager.mm
//  foo_jl_queue_manager
//
//  Singleton manager for playback queue callbacks
//

#import "QueueCallbackManager.h"
#import "../UI/QueueManagerController.h"
#import "../Core/QueueConfig.h"
#import "../Core/ConfigHelper.h"
#import "../Core/QueueOperations.h"
#import <Foundation/Foundation.h>

QueueCallbackManager::QueueCallbackManager() {
    m_controllers = [NSPointerArray weakObjectsPointerArray];
}

QueueCallbackManager& QueueCallbackManager::instance() {
    static QueueCallbackManager instance;
    return instance;
}

void QueueCallbackManager::registerController(QueueManagerController* controller) {
    std::lock_guard<std::mutex> lock(m_mutex);
    [m_controllers addPointer:(__bridge void*)controller];
}

void QueueCallbackManager::unregisterController(QueueManagerController* controller) {
    std::lock_guard<std::mutex> lock(m_mutex);

    for (NSUInteger i = 0; i < m_controllers.count; i++) {
        void* ptr = [m_controllers pointerAtIndex:i];
        if (ptr == (__bridge void*)controller) {
            [m_controllers removePointerAtIndex:i];
            break;
        }
    }
}

void QueueCallbackManager::onQueueChanged(playback_queue_callback::t_change_origin origin) {
    NSMutableArray<QueueManagerController*>* controllersToNotify = [NSMutableArray array];

    {
        std::lock_guard<std::mutex> lock(m_mutex);
        [m_controllers compact];

        for (NSUInteger i = 0; i < m_controllers.count; i++) {
            QueueManagerController* controller =
                (__bridge QueueManagerController*)[m_controllers pointerAtIndex:i];
            if (controller) {
                [controllersToNotify addObject:controller];
            }
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        for (QueueManagerController* controller in controllersToNotify) {
            if (controller.isReorderingInProgress) {
                continue;
            }
            [NSObject cancelPreviousPerformRequestsWithTarget:controller
                                                     selector:@selector(reloadQueueContents)
                                                       object:nil];
            [controller performSelector:@selector(reloadQueueContents)
                             withObject:nil
                             afterDelay:0.05];
        }
    });
}

#pragma mark - Playback Callbacks

void QueueCallbackManager::onPlaybackNewTrack(metadb_handle_ptr track) {
    {
        std::lock_guard<std::mutex> lock(m_playbackMutex);
        m_playingTrack = track;
        m_playbackPosition = 0;
        m_isPaused = false;
    }

    NSMutableArray<QueueManagerController*>* controllersToNotify = [NSMutableArray array];
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        [m_controllers compact];
        for (NSUInteger i = 0; i < m_controllers.count; i++) {
            QueueManagerController* c = (__bridge QueueManagerController*)[m_controllers pointerAtIndex:i];
            if (c) [controllersToNotify addObject:c];
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        for (QueueManagerController* c in controllersToNotify) {
            [c handlePlaybackNewTrack];
        }
    });
}

void QueueCallbackManager::onPlaybackStop(play_control::t_stop_reason reason) {
    {
        std::lock_guard<std::mutex> lock(m_playbackMutex);
        // Don't clear on shutdown — saveQueueState() needs the last playing track
        if (reason != play_control::stop_reason_shutting_down) {
            m_playingTrack.release();
            m_playbackPosition = 0;
        }
        m_isPaused = false;
    }

    NSMutableArray<QueueManagerController*>* controllersToNotify = [NSMutableArray array];
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        [m_controllers compact];
        for (NSUInteger i = 0; i < m_controllers.count; i++) {
            QueueManagerController* c = (__bridge QueueManagerController*)[m_controllers pointerAtIndex:i];
            if (c) [controllersToNotify addObject:c];
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        for (QueueManagerController* c in controllersToNotify) {
            [c handlePlaybackStop];
        }
    });
}

void QueueCallbackManager::onPlaybackPause(bool paused) {
    {
        std::lock_guard<std::mutex> lock(m_playbackMutex);
        m_isPaused = paused;
    }

    NSMutableArray<QueueManagerController*>* controllersToNotify = [NSMutableArray array];
    {
        std::lock_guard<std::mutex> lock(m_mutex);
        [m_controllers compact];
        for (NSUInteger i = 0; i < m_controllers.count; i++) {
            QueueManagerController* c = (__bridge QueueManagerController*)[m_controllers pointerAtIndex:i];
            if (c) [controllersToNotify addObject:c];
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        for (QueueManagerController* c in controllersToNotify) {
            [c handlePlaybackPause:paused];
        }
    });
}

void QueueCallbackManager::onPlaybackTime(double time) {
    {
        std::lock_guard<std::mutex> lock(m_playbackMutex);
        m_playbackPosition = time;
    }
}

metadb_handle_ptr QueueCallbackManager::getCurrentPlayingTrack() const {
    std::lock_guard<std::mutex> lock(m_playbackMutex);
    return m_playingTrack;
}

double QueueCallbackManager::getCurrentPlaybackPosition() const {
    std::lock_guard<std::mutex> lock(m_playbackMutex);
    return m_playbackPosition;
}

bool QueueCallbackManager::isPaused() const {
    std::lock_guard<std::mutex> lock(m_playbackMutex);
    return m_isPaused;
}

#pragma mark - Queue Persistence

void QueueCallbackManager::saveQueueState() {
    try {
        auto contents = queue_ops::getContentsVector();

        metadb_handle_ptr playingTrack;
        double playbackPos = 0;
        {
            std::lock_guard<std::mutex> lock(m_playbackMutex);
            playingTrack = m_playingTrack;
            playbackPos = m_playbackPosition;
        }

        // Check if playing track is already in the SDK queue
        bool playingInQueue = false;
        if (playingTrack.is_valid()) {
            for (size_t i = 0; i < contents.size(); i++) {
                if (contents[i].m_handle == playingTrack) {
                    playingInQueue = true;
                    break;
                }
            }
        }

        bool hasPlaying = playingTrack.is_valid() && !playingInQueue;

        if (contents.empty() && !hasPlaying) {
            queue_config::setConfigString(queue_config::kKeySavedQueuePaths, "");
            queue_config::setConfigInt(queue_config::kKeySavedPlayingIndex, -1);
            queue_config::setConfigInt(queue_config::kKeySavedPlaybackPosition, 0);
            return;
        }

        pfc::string8 pathsStr;
        int64_t playingIdx = -1;
        size_t writeIdx = 0;

        // Prepend the playing track (mirrors what the UI shows)
        if (hasPlaying) {
            pathsStr << playingTrack->get_path();
            playingIdx = 0;
            writeIdx = 1;
        }

        for (size_t i = 0; i < contents.size(); i++) {
            if (writeIdx > 0) pathsStr << "\n";
            if (contents[i].m_handle.is_valid()) {
                pathsStr << contents[i].m_handle->get_path();
                if (playingInQueue && contents[i].m_handle == playingTrack) {
                    playingIdx = (int64_t)writeIdx;
                }
            }
            writeIdx++;
        }

        queue_config::setConfigString(queue_config::kKeySavedQueuePaths, pathsStr.c_str());
        queue_config::setConfigInt(queue_config::kKeySavedPlayingIndex, playingIdx);
        queue_config::setConfigInt(queue_config::kKeySavedPlaybackPosition,
                                   (int64_t)(playbackPos * 100.0));

        console::info("[Queue Manager] Queue state saved");
    } catch (...) {
        console::error("[Queue Manager] Failed to save queue state");
    }
}

void QueueCallbackManager::restoreQueueState() {
    try {
        pfc::string8 pathsStr = queue_config::getConfigString(queue_config::kKeySavedQueuePaths, "");
        if (pathsStr.is_empty()) return;

        int64_t playingIdx = queue_config::getConfigInt(queue_config::kKeySavedPlayingIndex, -1);
        int64_t posCentis = queue_config::getConfigInt(queue_config::kKeySavedPlaybackPosition, 0);
        double savedPosition = (double)posCentis / 100.0;

        std::vector<std::string> paths;
        const char* p = pathsStr.c_str();
        const char* end = p + pathsStr.get_length();
        while (p < end) {
            const char* nl = strchr(p, '\n');
            if (!nl) nl = end;
            if (nl > p) {
                paths.emplace_back(p, nl - p);
            }
            p = nl + 1;
        }

        if (paths.empty()) return;

        auto db = metadb::get();
        auto pm = playlist_manager::get();

        if (pm->queue_get_count() > 0) return;

        // Add all items (including the previously-playing track) to the queue
        int itemsAdded = 0;
        for (const auto& path : paths) {
            auto handle = db->handle_create(path.c_str(), 0);
            if (handle.is_valid()) {
                pm->queue_add_item(handle);
                itemsAdded++;
            }
        }

        FB2K_console_formatter() << "[Queue Manager] Restored " << itemsAdded << " queue items";

        // If there was a playing track, start playback (paused) and seek to saved position.
        // Deferred to main queue so it runs after on_init() completes and the audio system is ready.
        if (playingIdx >= 0 && itemsAdded > 0) {
            double posToSeek = savedPosition;
            dispatch_async(dispatch_get_main_queue(), ^{
                try {
                    auto pc = playback_control::get();
                    pc->start(playback_control::track_command_play, true);

                    if (posToSeek > 0.5) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(200 * NSEC_PER_MSEC)),
                            dispatch_get_main_queue(), ^{
                            try {
                                auto pc2 = playback_control::get();
                                if (pc2->is_playing() && pc2->playback_can_seek()) {
                                    pc2->playback_seek(posToSeek);
                                    // Store restored position so saveQueueState has it
                                    // if the user closes again without playing.
                                    QueueCallbackManager::instance().onPlaybackTime(posToSeek);
                                }
                            } catch (...) {}
                        });
                    }
                } catch (...) {}
            });
        }

        // Clear saved state
        queue_config::setConfigString(queue_config::kKeySavedQueuePaths, "");
        queue_config::setConfigInt(queue_config::kKeySavedPlayingIndex, -1);
        queue_config::setConfigInt(queue_config::kKeySavedPlaybackPosition, 0);
    } catch (...) {
        console::error("[Queue Manager] Failed to restore queue state");
    }
}
