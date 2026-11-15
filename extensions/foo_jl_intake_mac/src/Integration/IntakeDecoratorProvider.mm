//
//  IntakeDecoratorProvider.mm
//  foo_jl_intake
//
//  The intake system's jl_row_decorator_provider (intake doc 04, Part B).
//  It answers from the IntakeView that the loader (IntakeService,
//  IntakeLoader) publishes; it never runs the CLI or touches the filesystem.
//
//  decorate() (PLAN.md 3.2; jl_decorator_api.h threading contract): called
//  off the main thread on one serial queue per SimPlaylist panel, possibly
//  concurrently across panels. It copies the view's shared_ptr under a short
//  lock, then per row, inside an autorelease pool: get_path ->
//  IntakeNativePath (g_get_native_path inline for mac-volume://, other
//  schemes no match) -> IntakeView::visualFor (normalize, mount alias,
//  snapshot lookup) -> a copy into jl_row_decoration. No I/O, no CLI, no
//  invalidate fired from here, so it returns promptly (v2's shutdown waits
//  for in-flight batches); g_get_native_path on a stale or unmounted UUID
//  is the one unmeasured call, so IntakeNativePath times it and stops
//  calling it for a volume once three calls in a row took over 20 ms (B4
//  IntakeSlowVolumeGuard, until the next mount change or Refresh). Before the first load
//  there is no view and every row is answered empty, never pending: v2
//  commits a pending answer like an empty one, and the loader fires
//  invalidate-all after its first load.
//
//  decorate_group (B6), in providerDecorateGroup: the same per-row pipeline
//  for each member the host passes (at most 64): get_path ->
//  IntakeNativePath -> IntakeView::recordFor. When every member that maps
//  belongs to one root, that root's badge (IntakeGroupBadge, computed when
//  the snapshot was built) fills the jl_group_decoration; no badge for mixed
//  groups, an inert view, or a root that is not proposed or approved. No
//  I/O, like decorate(). The test_actions `badge` step (temporary) calls the
//  same function on the main thread.
//
//  context_actions / execute_context_action (main thread) go to
//  IntakeActions, which keeps the table the menu was built from.
//
//  decor_stats (hidden, docs/hidden-options.md): with it off, a batch pays
//  one relaxed atomic load; with it on, each batch is timed and one
//  cumulative line is logged whatever log_level is (IntakeDecorStats).
//

#import "../fb2k_sdk.h"

#include "IntakeActions.h"
#include "IntakeDecoratorProvider.h"
#include "IntakeNativePath.h"

#include "../Core/IntakeDecorStats.h"
#include "../Core/IntakeDecorationMap.h"
#include "../Core/IntakeGroupBadge.h"
#include "../Core/IntakeLog.h"
#include "../Core/IntakeView.h"
#include "../../../../shared/jl_decorator_api.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <mutex>
#include <vector>

// IntakeIcon mirrors jl_icon_id value for value (append-only ABI), and a
// visual's colours are jl_rgba_t, so the copy below is a plain cast.
static_assert(sizeof(intake::IntakeRgba) == sizeof(jl_rgba_t), "IntakeRgba is jl_rgba_t");
static_assert(sizeof(intake::IntakeIcon) == sizeof(jl_icon_id), "IntakeIcon has jl_icon_id's size");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::None) == jl_icon_none, "icon None");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::CircleOpen) == jl_icon_circle_open, "icon CircleOpen");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::CircleLeftHalf) == jl_icon_circle_left_half,
              "icon CircleLeftHalf");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::CircleRightHalf) == jl_icon_circle_right_half,
              "icon CircleRightHalf");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::CircleFilled) == jl_icon_circle_filled, "icon CircleFilled");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::Warning) == jl_icon_warning, "icon Warning");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::Cross) == jl_icon_cross, "icon Cross");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::Check) == jl_icon_check, "icon Check");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::ArrowRight) == jl_icon_arrow_right, "icon ArrowRight");

namespace intake {

namespace {

struct ProviderState {
    std::mutex viewMutex;
    std::shared_ptr<const IntakeView> view;  // null until the first publish

    std::mutex callbackMutex;
    std::vector<jl_decoration_invalidate_callback *> callbacks;

    std::atomic<bool> statsEnabled{false};
    DecorStats stats;
};

// Leaked on purpose: no static destructor, so the host may still register,
// unregister or be called back after on_quit and during process exit.
ProviderState &providerState() {
    static ProviderState *state = new ProviderState();
    return *state;
}

std::shared_ptr<const IntakeView> currentView(ProviderState &state) {
    std::lock_guard<std::mutex> lock(state.viewMutex);
    return state.view;
}

void fireInvalidateAll(ProviderState &state) {
    std::vector<jl_decoration_invalidate_callback *> callbacks;
    {
        std::lock_guard<std::mutex> lock(state.callbackMutex);
        callbacks = state.callbacks;
    }
    state.stats.noteInvalidation();
    if (isLogEnabled(LogLevel::Debug)) {
        logDebug("invalidate-all to " + std::to_string(callbacks.size()) + " host panel(s)");
    }
    // Outside the lock: a host that re-enters the provider from its
    // callback must not deadlock against registration.
    metadb_handle_list everything;  // empty: everything from this provider changed
    for (jl_decoration_invalidate_callback *cb : callbacks) {
        cb->on_decorations_invalidated(everything);
    }
}

void copyVisual(const IntakeRowVisual &visual, jl_row_decoration &out) {
    out.bg_tint = visual.bgTint;
    out.icon = static_cast<jl_icon_id>(visual.icon);
    out.icon_color = visual.iconColor;
    if (!visual.tooltip.empty()) out.tooltip.set_string(visual.tooltip.data(), visual.tooltip.size());
    out.strikethrough = visual.strikethrough;
    out.pending = false;
}

class intake_decorator_provider : public jl_row_decorator_provider {
public:
    void decorate(metadb_handle_list_cref items, pfc::list_t<jl_row_decoration> &out) override {
        const t_size count = items.get_count();
        // Contract: index-aligned with items, default entries mean "no
        // decoration". Cleared first in case the host reuses the list.
        out.remove_all();
        out.set_count(count);

        ProviderState &state = providerState();
        const bool stats = state.statsEnabled.load(std::memory_order_relaxed);
        const auto start = stats ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point();

        const std::shared_ptr<const IntakeView> view = currentView(state);
        if (view && !view->rendersNothing()) {
            pfc::string8 native;
            ViewScratch scratch;
            for (t_size i = 0; i < count; i++) {
                @autoreleasepool {
                    const metadb_handle_ptr handle = items[i];
                    if (!handle.is_valid()) continue;
                    const char *path = intakeNativePath(handle->get_path(), native);
                    if (path == nullptr) continue;
                    if (const IntakeRowVisual *visual = view->visualFor(path, scratch)) copyVisual(*visual, out[i]);
                }
            }
        }

        if (stats) {
            const auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
                                    std::chrono::steady_clock::now() - start)
                                    .count();
            state.stats.noteBatch(count, static_cast<uint64_t>(micros));
            // Unfiltered: the option is an explicit opt-in, so log_level 0
            // must not swallow the measurement (docs/hidden-options.md).
            logUnfiltered(LogLevel::Info, DecorStats::formatLine(state.stats.figures()));
        }
    }

    bool decorate_group(const jl_group_key &key, metadb_handle_list_cref members,
                        jl_group_decoration &out) override {
        (void)key;
        return providerDecorateGroup(members, out);
    }

    void context_actions(metadb_handle_list_cref sel, pfc::list_t<jl_context_action> &out) override {
        actionsBuildMenu(sel, out);
    }

    void execute_context_action(uint32_t action_id, metadb_handle_list_cref sel) override {
        // The table built with the menu holds everything the action needs;
        // the host releases `sel` as soon as this returns.
        (void)sel;
        actionsExecute(action_id);
    }

    void register_invalidate_callback(jl_decoration_invalidate_callback *cb) override {
        if (cb == nullptr) return;
        ProviderState &state = providerState();
        bool added = false;
        {
            std::lock_guard<std::mutex> lock(state.callbackMutex);
            // Contract: several callbacks at once, one per host panel.
            if (std::find(state.callbacks.begin(), state.callbacks.end(), cb) == state.callbacks.end()) {
                state.callbacks.push_back(cb);
                added = true;
            }
        }
        // A panel that registers after a view was published missed that
        // publish's invalidate-all. SimPlaylist v2 registers before it
        // decorates, so nothing is stale there, but the API does not promise
        // that order: send this one callback an invalidate-all, off the
        // registering call, if it is still registered by then.
        if (added && currentView(state) != nullptr) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                ProviderState &s = providerState();
                {
                    std::lock_guard<std::mutex> lock(s.callbackMutex);
                    if (std::find(s.callbacks.begin(), s.callbacks.end(), cb) == s.callbacks.end()) return;
                }
                logDebug("invalidate-all to a host panel that registered after the last publish");
                metadb_handle_list everything;
                cb->on_decorations_invalidated(everything);
            });
        }
    }

    void unregister_invalidate_callback(jl_decoration_invalidate_callback *cb) override {
        // Contract: tolerate a callback that was never registered; also
        // works after on_quit (the state is never destroyed).
        ProviderState &state = providerState();
        std::lock_guard<std::mutex> lock(state.callbackMutex);
        state.callbacks.erase(std::remove(state.callbacks.begin(), state.callbacks.end(), cb),
                              state.callbacks.end());
    }
};

FB2K_SERVICE_FACTORY(intake_decorator_provider);

} // anonymous namespace

void providerPublish(std::shared_ptr<const IntakeView> view, bool invalidateAll, bool countAsLoad) {
    ProviderState &state = providerState();
    {
        std::lock_guard<std::mutex> lock(state.viewMutex);
        state.view.swap(view);
    }
    view.reset();  // the previous view, released outside the lock
    if (countAsLoad) state.stats.noteLoad();
    if (invalidateAll) fireInvalidateAll(state);
}

void providerInvalidateAll() {
    fireInvalidateAll(providerState());
}

void providerSetStatsEnabled(bool enabled) {
    providerState().statsEnabled.store(enabled, std::memory_order_relaxed);
}

std::shared_ptr<const IntakeView> providerCurrentView() {
    return currentView(providerState());
}

bool providerDecorateGroup(metadb_handle_list_cref members, jl_group_decoration &out) {
    const std::shared_ptr<const IntakeView> view = currentView(providerState());
    if (!view || view->rendersNothing() || view->isInert()) return false;
    const t_size count = members.get_count();
    std::vector<const IntakeRecord *> records;
    records.reserve(count);
    pfc::string8 native;
    ViewScratch scratch;
    for (t_size i = 0; i < count; i++) {
        @autoreleasepool {
            const metadb_handle_ptr handle = members[i];
            if (!handle.is_valid()) continue;
            const char *path = intakeNativePath(handle->get_path(), native);
            if (path == nullptr) continue;
            const IntakeRecord *record = view->recordFor(path, scratch);
            if (record == nullptr) continue;
            // Two roots in one group: no badge, no need to look further.
            if (!records.empty() && records.front()->id != record->id) return false;
            records.push_back(record);
        }
    }
    const IntakeBadge *badge = groupBadge(records);
    if (badge == nullptr) return false;
    out.badge_text.set_string(badge->text.data(), badge->text.size());
    out.badge_color = badge->color;
    out.icon = jl_icon_none;
    return true;
}

} // namespace intake
