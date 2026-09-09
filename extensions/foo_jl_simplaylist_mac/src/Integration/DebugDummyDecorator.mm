//
//  DebugDummyDecorator.mm
//  foo_simplaylist_mac
//
//  Debug-only dummy jl_row_decorator_provider used to exercise the decorator
//  integration (intake doc 04 Part A) before a real provider exists. NOT
//  SHIPPED: the whole file compiles only in Debug builds, and even there the
//  service registers only when the environment variable
//  SIMPLAYLIST_DECOR_DUMMY=1 is set when foobar2000 launches, so debug builds
//  behave exactly like release (zero providers) unless explicitly testing:
//
//      SIMPLAYLIST_DECOR_DUMMY=1 open -a foobar2000
//
//  Decorates a deterministic subset of rows (by path hash) with the full
//  visual vocabulary (tint, icon, tooltip, strikethrough), badges matching
//  groups, and contributes two context actions; "Dummy: Toggle Decorations"
//  flips all decorations off/on and fires the invalidate callback, which
//  exercises the cache-invalidation and re-query path end to end.
//

#if DEBUG

#import "../fb2k_sdk.h"
#import "../../../../shared/jl_decorator_api.h"

#include <atomic>
#include <cstdlib>
#include <mutex>
#include <vector>

namespace {

std::atomic<bool> g_dummyActive{true};

uint32_t pathHash(const metadb_handle_ptr &handle) {
    const char *path = handle->get_path();
    uint32_t h = 2166136261u;  // FNV-1a
    for (const char *c = path; *c; c++) {
        h = (h ^ (uint8_t)*c) * 16777619u;
    }
    return h;
}

class debug_dummy_decorator : public jl_row_decorator_provider {
public:
    void decorate(metadb_handle_list_cref items,
                  pfc::list_t<jl_row_decoration> &out) override {
        out.set_count(items.get_count());
        if (!g_dummyActive.load(std::memory_order_relaxed)) return;

        for (t_size i = 0; i < items.get_count(); i++) {
            jl_row_decoration &dec = out[i];
            switch (pathHash(items[i]) % 10) {
                case 0:
                    dec.bg_tint = jl_rgba(0x4A, 0x90, 0xD9, 0x38);  // intake blue
                    dec.icon = jl_icon_circle_open;
                    dec.tooltip = "dummy: new/resolved";
                    break;
                case 1:
                    dec.bg_tint = jl_rgba(0xE5, 0xA5, 0x0A, 0x38);  // amber
                    dec.icon = jl_icon_warning;
                    dec.icon_color = jl_rgba(0xE5, 0xA5, 0x0A, 0xFF);
                    dec.tooltip = "dummy: needs review";
                    break;
                case 2:
                    dec.bg_tint = jl_rgba(0x2A, 0xA1, 0x98, 0x38);  // teal
                    dec.icon = jl_icon_circle_left_half;
                    dec.tooltip = "dummy: proposed";
                    break;
                case 3:
                    dec.bg_tint = jl_rgba(0x3F, 0xB9, 0x50, 0x38);  // green
                    dec.icon = jl_icon_circle_filled;
                    dec.icon_color = jl_rgba(0x3F, 0xB9, 0x50, 0xFF);
                    dec.tooltip = "dummy: placed (verified)";
                    break;
                case 4:
                    dec.bg_tint = jl_rgba(0x80, 0x80, 0x80, 0x28);  // grey
                    dec.icon = jl_icon_cross;
                    dec.strikethrough = true;
                    dec.tooltip = "dummy: rejected";
                    break;
                default:
                    break;  // Undecorated
            }
        }
    }

    bool decorate_group(const jl_group_key &key,
                        metadb_handle_list_cref members,
                        jl_group_decoration &out) override {
        if (!g_dummyActive.load(std::memory_order_relaxed)) return false;
        if (members.get_count() == 0) return false;
        if (pathHash(members[0]) % 4 != 0) return false;
        out.badge_text = "-> [Dummy Target] 0.91";
        out.badge_color = jl_rgba(0x2A, 0xA1, 0x98, 0xFF);
        out.icon = jl_icon_arrow_right;
        return true;
    }

    void context_actions(metadb_handle_list_cref sel,
                         pfc::list_t<jl_context_action> &out) override {
        jl_context_action toggle;
        toggle.title = g_dummyActive.load(std::memory_order_relaxed)
            ? "Dummy: Disable Decorations" : "Dummy: Enable Decorations";
        toggle.action_id = kActionToggle;
        out.add_item(toggle);

        jl_context_action log;
        log.title = "Dummy: Log Selection";
        log.action_id = kActionLog;
        log.enabled = sel.get_count() > 0;
        out.add_item(log);
    }

    void execute_context_action(uint32_t action_id,
                                metadb_handle_list_cref sel) override {
        switch (action_id) {
            case kActionToggle: {
                bool nowActive = !g_dummyActive.load(std::memory_order_relaxed);
                g_dummyActive.store(nowActive, std::memory_order_relaxed);
                FB2K_console_formatter() << "[SimPlaylist dummy] decorations "
                                         << (nowActive ? "enabled" : "disabled");
                fireInvalidateAll();
                break;
            }
            case kActionLog:
                FB2K_console_formatter() << "[SimPlaylist dummy] selection: "
                                         << (unsigned)sel.get_count() << " item(s)";
                break;
            default:
                break;
        }
    }

    void register_invalidate_callback(jl_decoration_invalidate_callback *cb) override {
        std::lock_guard<std::mutex> lock(m_callbackMutex);
        m_callbacks.push_back(cb);
    }

    void unregister_invalidate_callback(jl_decoration_invalidate_callback *cb) override {
        std::lock_guard<std::mutex> lock(m_callbackMutex);
        m_callbacks.erase(std::remove(m_callbacks.begin(), m_callbacks.end(), cb),
                          m_callbacks.end());
    }

private:
    enum : uint32_t { kActionToggle = 1, kActionLog = 2 };

    void fireInvalidateAll() {
        std::vector<jl_decoration_invalidate_callback *> callbacks;
        {
            std::lock_guard<std::mutex> lock(m_callbackMutex);
            callbacks = m_callbacks;
        }
        metadb_handle_list empty;  // Empty list = invalidate everything
        for (auto *cb : callbacks) {
            cb->on_decorations_invalidated(empty);
        }
    }

    std::mutex m_callbackMutex;
    std::vector<jl_decoration_invalidate_callback *> m_callbacks;
};

// Registered only when SIMPLAYLIST_DECOR_DUMMY=1: the factory is a
// function-local static inside the conditional, so without the variable the
// service never enters the registration chain and debug builds keep true
// zero-provider behavior.
struct DummyDecoratorRegistrar {
    DummyDecoratorRegistrar() {
        const char *enabled = std::getenv("SIMPLAYLIST_DECOR_DUMMY");
        if (enabled && enabled[0] == '1' && enabled[1] == '\0') {
            static service_factory_single_t<debug_dummy_decorator> g_factory;
        }
    }
};
DummyDecoratorRegistrar g_dummyDecoratorRegistrar;

}  // namespace

#endif  // DEBUG
