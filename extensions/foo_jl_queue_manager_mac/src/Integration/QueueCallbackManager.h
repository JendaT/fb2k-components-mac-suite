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
#include <vector>

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

    // Called by playback_queue_callback service when queue changes
    void onQueueChanged(playback_queue_callback::t_change_origin origin);

private:
    QueueCallbackManager() = default;
    ~QueueCallbackManager() = default;

    // Non-copyable
    QueueCallbackManager(const QueueCallbackManager&) = delete;
    QueueCallbackManager& operator=(const QueueCallbackManager&) = delete;

    std::mutex m_mutex;

    // Using void* to store __weak references in C++
    // The actual weak reference handling is done in the .mm file
    std::vector<void*> m_controllers;
};
