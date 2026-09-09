//
//  QueueCallbackManager.h
//  foo_jl_queue_manager
//
//  Singleton manager for playback queue callbacks
//  Handles multiple controller instances and proper lifecycle management
//

#pragma once

#include <foobar2000/SDK/foobar2000.h>
#include <mutex>

#ifdef __OBJC__
@class QueueManagerController;
#else
typedef void QueueManagerController;
#endif

class QueueCallbackManager {
public:
    // Meyer's singleton
    static QueueCallbackManager& instance();

    // Register a controller to receive queue change notifications
    void registerController(QueueManagerController* controller);

    // Unregister a controller (call from dealloc)
    void unregisterController(QueueManagerController* controller);

    void onQueueChanged(playback_queue_callback::t_change_origin origin);

    void onPlaybackNewTrack(metadb_handle_ptr track);
    void onPlaybackStop(play_control::t_stop_reason reason);
    void onPlaybackPause(bool paused);
    void onPlaybackTime(double time);

    void saveQueueState();
    void restoreQueueState();

    metadb_handle_ptr getCurrentPlayingTrack() const;
    double getCurrentPlaybackPosition() const;
    bool isPaused() const;

private:
    QueueCallbackManager();
    ~QueueCallbackManager() = default;

    QueueCallbackManager(const QueueCallbackManager&) = delete;
    QueueCallbackManager& operator=(const QueueCallbackManager&) = delete;

    std::mutex m_mutex;
    mutable std::mutex m_playbackMutex;
    metadb_handle_ptr m_playingTrack;
    double m_playbackPosition = 0;
    bool m_isPaused = false;

#ifdef __OBJC__
    NSPointerArray* m_controllers;
#else
    void* m_controllers;
#endif
};
