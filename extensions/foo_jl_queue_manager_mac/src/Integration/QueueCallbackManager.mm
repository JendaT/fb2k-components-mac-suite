//
//  QueueCallbackManager.mm
//  foo_jl_queue_manager
//
//  Singleton manager for playback queue callbacks
//

#import "QueueCallbackManager.h"
#import "../UI/QueueManagerController.h"
#import <Foundation/Foundation.h>

// Rapid queue callbacks (e.g. the N+1 storm from a flush-and-readd reorder)
// within this window coalesce into a single reload.
static const NSTimeInterval kReloadCoalesceDelay = 0.05;

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
    // Collect controllers to notify under lock, using NSArray for ARC retention
    NSMutableArray<QueueManagerController*>* controllersToNotify = [NSMutableArray array];

    {
        std::lock_guard<std::mutex> lock(m_mutex);

        // Compact removes zeroed-out weak references
        [m_controllers compact];

        for (NSUInteger i = 0; i < m_controllers.count; i++) {
            QueueManagerController* controller =
                (__bridge QueueManagerController*)[m_controllers pointerAtIndex:i];
            if (controller) {
                [controllersToNotify addObject:controller];
            }
        }
    }

    // Nothing to notify: skip the main-queue dispatch entirely
    if (controllersToNotify.count == 0) {
        return;
    }

    // Coalesce rapid callbacks: cancel pending reload and schedule a new one.
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
                             afterDelay:kReloadCoalesceDelay];
        }
    });
}
