//
//  QueueCallback.mm
//  foo_jl_queue_manager
//
//  Service factory for playback_queue_callback
//  Delegates to QueueCallbackManager singleton
//

#import "QueueCallbackManager.h"
#import "StopAfterQueue.h"
#include <foobar2000/SDK/foobar2000.h>
#include "../Core/ConfigHelper.h"
#include "../Core/QueueConfig.h"
#include "../Core/QueueOperations.h"
#include "../Core/QueuePersistence.h"

namespace {

// Playback queue callback implementation
class queue_callback_impl : public playback_queue_callback {
public:
    void on_changed(t_change_origin origin) override {
        stop_after_queue::onQueueChanged(origin);
        QueueCallbackManager::instance().onQueueChanged(origin);
    }
};

FB2K_SERVICE_FACTORY(queue_callback_impl);

// foobar2000 does not keep the playback queue across restarts, so it is
// saved on quit and re-added on the next start (when enabled).
void restoreSavedQueue() {
    using namespace queue_config;
    if (!getConfigBool(kKeyPersistQueue, kDefaultPersistQueue)) return;

    try {
        auto entries = queue_persist::deserialize(
            getConfigString(kKeySavedQueue, "").c_str());
        if (entries.empty()) return;

        // Never append to a queue something else already populated
        if (queue_ops::getCount() > 0) return;

        size_t added = queue_ops::restoreFromPersistence(entries);
        pfc::string8 msg;
        msg << "[Queue Manager] Restored " << added << " queued item(s)";
        console::info(msg);
    } catch (const std::exception& e) {
        pfc::string8 msg;
        msg << "[Queue Manager] Queue restore failed: " << e.what();
        console::error(msg);
    }
}

void saveQueue() {
    using namespace queue_config;
    try {
        // Disabled: clear any old snapshot so re-enabling later does not
        // resurrect a stale queue
        std::string blob;
        if (getConfigBool(kKeyPersistQueue, kDefaultPersistQueue)) {
            blob = queue_persist::serialize(queue_ops::captureForPersistence());
        }
        setConfigString(kKeySavedQueue, blob.c_str());
    } catch (const std::exception& e) {
        pfc::string8 msg;
        msg << "[Queue Manager] Queue save failed: " << e.what();
        console::error(msg);
    }
}

// Initialization/shutdown
class queue_manager_init : public initquit {
public:
    void on_init() override {
        // Initialize the callback manager singleton
        QueueCallbackManager::instance();
        restoreSavedQueue();
        console::info("[Queue Manager] Initialized");
    }

    void on_quit() override {
        // Controllers unregister themselves; only the queue needs saving
        saveQueue();

        stop_after_queue::shutdown();
    }
};

FB2K_SERVICE_FACTORY(queue_manager_init);

} // namespace
