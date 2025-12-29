//
//  QueueCallback.mm
//  foo_jl_queue_manager
//
//  Service factory for playback_queue_callback
//  Delegates to QueueCallbackManager singleton
//

#import "QueueCallbackManager.h"
#include <foobar2000/SDK/foobar2000.h>

namespace {

// Playback queue callback implementation
class queue_callback_impl : public playback_queue_callback {
public:
    void on_changed(t_change_origin origin) override {
        QueueCallbackManager::instance().onQueueChanged(origin);
    }
};

FB2K_SERVICE_FACTORY(queue_callback_impl);

// Initialization/shutdown
class queue_manager_init : public initquit {
public:
    void on_init() override {
        // Initialize the callback manager singleton
        QueueCallbackManager::instance();
        console::info("[Queue Manager] Initialized");
    }

    void on_quit() override {
        // Nothing to clean up - controllers unregister themselves
    }
};

FB2K_SERVICE_FACTORY(queue_manager_init);

} // namespace
