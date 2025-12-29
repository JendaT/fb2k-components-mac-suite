//
//  QueueCallbackManager.mm
//  foo_jl_queue_manager
//
//  Singleton manager for playback queue callbacks
//

#import "QueueCallbackManager.h"
#import "../UI/QueueManagerController.h"
#import <Foundation/Foundation.h>

QueueCallbackManager& QueueCallbackManager::instance() {
    static QueueCallbackManager instance;
    return instance;
}

void QueueCallbackManager::registerController(QueueManagerController* controller) {
    std::lock_guard<std::mutex> lock(m_mutex);

    // Store as a bridged pointer (controller is __weak in practice)
    // We'll clean up nil references in onQueueChanged
    m_controllers.push_back((__bridge void*)controller);
}

void QueueCallbackManager::unregisterController(QueueManagerController* controller) {
    std::lock_guard<std::mutex> lock(m_mutex);

    auto it = std::find(m_controllers.begin(), m_controllers.end(), (__bridge void*)controller);
    if (it != m_controllers.end()) {
        m_controllers.erase(it);
    }
}

void QueueCallbackManager::onQueueChanged(playback_queue_callback::t_change_origin origin) {
    // Capture controllers to notify (under lock)
    std::vector<QueueManagerController*> controllersToNotify;

    {
        std::lock_guard<std::mutex> lock(m_mutex);

        // Clean up nil references and collect valid controllers
        std::vector<void*> validControllers;
        for (void* ptr : m_controllers) {
            QueueManagerController* controller = (__bridge QueueManagerController*)ptr;
            if (controller != nil) {
                validControllers.push_back(ptr);
                controllersToNotify.push_back(controller);
            }
        }
        m_controllers = validControllers;
    }

    // Dispatch to main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        for (QueueManagerController* controller : controllersToNotify) {
            // Skip if controller is in the middle of reordering (debounce)
            if (controller.isReorderingInProgress) {
                continue;
            }
            [controller reloadQueueContents];
        }
    });
}
