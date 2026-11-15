//
//  IntakeDecoratorProvider.mm
//  foo_jl_intake
//
//  The intake system's jl_row_decorator_provider (intake doc 04, Part B) —
//  the first real consumer of the Part A extension point.
//
//  SCAFFOLD STATE: this provider registers and honours the full API contract
//  but has no state to decorate with yet. The root index is always empty, so
//  every decorate() answers "no decoration" and every decorate_group() answers
//  false. Installing the component therefore adds an empty 16 pt gutter to
//  SimPlaylist and nothing else — provider PRESENCE is what enables the gutter
//  (doc 04, Part A), not provider activity.
//
//  State acquisition (`intake version` gate, `intake status --json` load,
//  FSEvents watch) is deliberately absent: it is blocked on doc 03 change
//  requests CR-002.1 (is the status payload enveloped?) and CR-002.3 (which
//  schema version does the gate compare against?). See
//  docs/intake/CHANGE-REQUESTS.md. Building that parser against a guess would
//  be rework, so the scaffold stops at the boundary.
//
//  Threading (jl_decorator_api.h): decorate()/decorate_group() arrive off the
//  main thread and may arrive CONCURRENTLY (one query queue per SimPlaylist
//  panel), so all shared state lives behind m_stateMutex. Neither call may
//  block: no I/O, no subprocess, no waiting on the main thread. Once the CLI
//  bridge exists, a cache miss must answer pending=true and re-request after
//  the invalidate callback rather than shelling out inline.
//

#import "../fb2k_sdk.h"
#import "../Core/IntakeRootIndex.h"
#import "../../../../shared/jl_decorator_api.h"

#include <algorithm>
#include <mutex>
#include <vector>

namespace {

class intake_decorator_provider : public jl_row_decorator_provider {
public:
    void decorate(metadb_handle_list_cref items,
                  pfc::list_t<jl_row_decoration> &out) override {
        // Contract: out must be resized to items.get_count() and index-aligned;
        // default-constructed entries mean "no decoration".
        out.set_count(items.get_count());

        std::lock_guard<std::mutex> lock(m_stateMutex);
        if (m_rootIndex.rootCount == 0) {
            // Nothing indexed: every row is undecorated. Returning early keeps
            // the empty case free of per-row work, mirroring the zero-provider
            // guard on the host side.
            return;
        }
        // Per-row resolution lands here once state acquisition exists.
    }

    bool decorate_group(const jl_group_key &key,
                        metadb_handle_list_cref members,
                        jl_group_decoration &out) override {
        (void)key;
        (void)members;
        (void)out;
        return false;  // No proposal badges until status data is loaded.
    }

    void context_actions(metadb_handle_list_cref sel,
                         pfc::list_t<jl_context_action> &out) override {
        (void)sel;
        out.set_count(0);
        // The doc 04 Part B menu (Propose / Assign to <alternates> / Approve /
        // Execute / Delete local copy / Swap to library paths) attaches here.
        // "Assign to <alternates>" additionally needs CR-002.2
        // (proposal.ranked in the status summary) to avoid parsing sidecars.
    }

    void execute_context_action(uint32_t action_id,
                                metadb_handle_list_cref sel) override {
        (void)sel;
        // No actions are offered yet, so anything arriving here is a host bug
        // or a stale menu; log rather than fail silently.
        FB2K_console_formatter()
            << "[intake] unexpected context action " << (unsigned)action_id
            << " (provider offers none in this build)";
    }

    void register_invalidate_callback(jl_decoration_invalidate_callback *cb) override {
        if (cb == nullptr) return;
        std::lock_guard<std::mutex> lock(m_callbackMutex);
        // Contract: multiple concurrent callbacks, one per host panel.
        if (std::find(m_callbacks.begin(), m_callbacks.end(), cb) == m_callbacks.end()) {
            m_callbacks.push_back(cb);
        }
    }

    void unregister_invalidate_callback(jl_decoration_invalidate_callback *cb) override {
        std::lock_guard<std::mutex> lock(m_callbackMutex);
        // Contract: tolerate a callback that was never registered.
        m_callbacks.erase(std::remove(m_callbacks.begin(), m_callbacks.end(), cb),
                          m_callbacks.end());
    }

private:
    // Fires "everything changed" at every host panel. Unused until state
    // acquisition lands; kept because the copy-then-invoke shape is the part
    // that is easy to get wrong -- invoking under the lock would deadlock
    // against a host that re-enters the provider from its callback.
    void fireInvalidateAll() {
        std::vector<jl_decoration_invalidate_callback *> callbacks;
        {
            std::lock_guard<std::mutex> lock(m_callbackMutex);
            callbacks = m_callbacks;
        }
        metadb_handle_list empty;  // Empty list = invalidate everything.
        for (auto *cb : callbacks) {
            cb->on_decorations_invalidated(empty);
        }
    }

    std::mutex m_stateMutex;
    IntakeRootIndex *m_rootIndex = [[IntakeRootIndex alloc] init];

    std::mutex m_callbackMutex;
    std::vector<jl_decoration_invalidate_callback *> m_callbacks;
};

FB2K_SERVICE_FACTORY(intake_decorator_provider);

}  // namespace
