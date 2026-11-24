//
//  IntakeStatusProvider.mm
//  foo_jl_intake
//
//  The intake system's jl_status_provider (B14; PLAN-B14 section 2,
//  "Provider"; shared/jl_status_api.h): what intake is doing now, and what
//  it finished in the last 10 seconds, for a host's status area. SimPlaylist
//  shows the line as a pill at the bottom right of the panel with the
//  active playlist and the list in a popover. The provider reads the
//  session's activity model (IntakeActivityHub, IntakeActivity) and maps it
//  with IntakeActivityStatus; it never runs the CLI or touches the
//  filesystem.
//
//  The line (status_line, main thread, O(1), never blocks): the hub calls
//  the provider's change handler on the main thread after every change that
//  may alter the line or the list (begin, progress, rename, end, the 10 s
//  expiry of a result, quit). The handler takes model.line(now) once and
//  keeps it as a jl_status_line; status_line copies that out, or answers
//  false when the model has no line (idle). No lock: the cached line is
//  main-thread only, like every call that reads or writes it.
//
//  The list (status_items, main thread, only while a host's list is open):
//  model.items(now) mapped field by field, a handful of entries; ids stable
//  while an entry exists, started/ended in Unix epoch milliseconds.
//
//  Callbacks (register/unregister on the main thread): several at once,
//  each pointer once; unregistering one that is not there does nothing
//  (IntakeCallbackList). The handler fires every registered callback once
//  per model change, on the main thread, from a copy of the list outside
//  its lock, skipping one unregistered since the round began; so after
//  unregister returns, a callback is called again only if its call had
//  already begun. A host coalesces (SimPlaylist reads at most about 4 times
//  a second); the provider sends one call per change and adds no timer of
//  its own.
//
//  Time. The host has no timer: a result line that expires after 10 s, or
//  a dry run that reaches its 15-minute deadline, must be announced. The
//  hub keeps one dispatch_after on the main queue at the model's nextExpiry
//  (re-armed on every change, none while no result is shown and no
//  deadline is pending, none after quit), on the wall clock, so it fires on
//  time after the Mac slept; when it fires, the hub prunes the model and
//  calls the handler, which takes the new line and fires the callbacks.
//
//  Cost with no host: the handler still takes the line on each change (one
//  pass over a handful of entries and a string copy), then finds no
//  callback under one uncontended lock and stops.
//
//  Quit: actionsShutdown empties the model and the hub calls the handler
//  once (the line goes, callbacks fire once); the hub then calls it never
//  again, so the provider answers false and an empty list, and fires
//  nothing. Its state is leaked on purpose (no static destructor): a host
//  may still unregister, or read, after on_quit and during process exit.
//

#import "../fb2k_sdk.h"

#include "IntakeActivityHub.h"
#include "IntakeStatusProvider.h"

#include "../Core/IntakeActivityStatus.h"
#include "../Core/IntakeCallbackList.h"
#include "../../../../shared/jl_status_api.h"

#include <optional>
#include <type_traits>
#include <vector>

// The Core mirrors carry the header's values (append-only ABI).
static_assert(std::is_same_v<std::underlying_type_t<jl_status_state>, uint32_t>, "jl_status_state is a uint32_t");
static_assert(static_cast<uint32_t>(intake::StatusFieldState::Queued) == jl_status_queued, "state Queued");
static_assert(static_cast<uint32_t>(intake::StatusFieldState::Running) == jl_status_running, "state Running");
static_assert(static_cast<uint32_t>(intake::StatusFieldState::Succeeded) == jl_status_succeeded, "state Succeeded");
static_assert(static_cast<uint32_t>(intake::StatusFieldState::Failed) == jl_status_failed, "state Failed");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::None) == jl_icon_none, "icon None");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::Check) == jl_icon_check, "icon Check");
static_assert(static_cast<uint32_t>(intake::IntakeIcon::Cross) == jl_icon_cross, "icon Cross");
// The numbers copied below go into fields of the same types.
static_assert(std::is_same_v<decltype(jl_status_line::done), uint32_t> &&
                  std::is_same_v<decltype(jl_status_line::total), uint32_t>,
              "jl_status_line's progress");
static_assert(std::is_same_v<decltype(jl_status_item::id), uint64_t> &&
                  std::is_same_v<decltype(jl_status_item::done), uint32_t> &&
                  std::is_same_v<decltype(jl_status_item::total), uint32_t> &&
                  std::is_same_v<decltype(jl_status_item::started_ms), int64_t> &&
                  std::is_same_v<decltype(jl_status_item::ended_ms), int64_t>,
              "jl_status_item's numbers");

namespace intake {

namespace {

struct StatusState {
    // main
    bool started = false;     // the hub's change handler is this provider's
    bool lineShown = false;   // false: status_line answers false
    jl_status_line line;      // the answer while lineShown

    // any thread (registration is on main, but the list is safe anywhere)
    CallbackList<jl_status_callback> callbacks;
};

// Leaked on purpose: no static destructor, so the host may still register,
// unregister or read after on_quit and during process exit.
StatusState &statusState() {
    static StatusState *state = new StatusState();
    return *state;
}

// Main: the line the model shows now, kept for status_line.
void takeLine(StatusState &state) {
    const std::optional<ActivityLine> line = activityModel().line(activityNowMs());
    if (!line) {
        state.lineShown = false;
        state.line.text.reset();
        state.line.done = 0;
        state.line.total = 0;
        state.line.icon = jl_icon_none;
        state.line.state = jl_status_running;
        return;
    }
    const StatusLineFields fields = statusLineFieldsFor(*line);
    state.line.text.set_string(fields.text.data(), fields.text.size());
    state.line.done = fields.done;
    state.line.total = fields.total;
    state.line.icon = static_cast<jl_icon_id>(fields.icon);
    state.line.state = static_cast<jl_status_state>(fields.state);
    state.lineShown = true;
}

// Main: the hub's change handler.
void activityChanged() {
    StatusState &state = statusState();
    takeLine(state);
    // Outside the list's lock (forEach), so a host that re-enters the
    // provider from its callback cannot deadlock against registration.
    state.callbacks.forEach([](jl_status_callback *cb) {
        cb->on_status_changed();
    });
}

class intake_status_provider : public jl_status_provider {
public:
    bool status_line(jl_status_line &out) override {
        statusProviderStart();
        const StatusState &state = statusState();
        if (!state.lineShown) return false;
        out = state.line;
        return true;
    }

    void status_items(pfc::list_t<jl_status_item> &out) override {
        statusProviderStart();
        // Contract: replaces the contents (the host may reuse the list).
        out.remove_all();
        const std::vector<ActivityItem> items = activityModel().items(activityNowMs());
        out.set_count(items.size());
        for (size_t i = 0; i < items.size(); i++) {
            const StatusItemFields fields = statusItemFieldsFor(items[i]);
            jl_status_item &item = out[i];
            item.id = fields.id;
            item.title.set_string(fields.title.data(), fields.title.size());
            item.detail.set_string(fields.detail.data(), fields.detail.size());
            item.state = static_cast<jl_status_state>(fields.state);
            item.done = fields.done;
            item.total = fields.total;
            item.started_ms = fields.startedMs;
            item.ended_ms = fields.endedMs;
        }
    }

    void register_status_callback(jl_status_callback *cb) override {
        statusProviderStart();
        // Contract: several at once, one per host panel. No call on
        // registration: a host reads the line after registering (the
        // header's "re-reads after a callback or a panel change";
        // SimPlaylist makes its first read right after enumeration).
        statusState().callbacks.add(cb);
    }

    void unregister_status_callback(jl_status_callback *cb) override {
        // Contract: tolerate a callback that was never registered; also
        // works after on_quit (the state is never destroyed).
        statusState().callbacks.remove(cb);
    }
};

FB2K_SERVICE_FACTORY(intake_status_provider);

} // anonymous namespace

void statusProviderStart() {
    StatusState &state = statusState();
    if (state.started) return;
    state.started = true;
    activitySetChangeHandler([] { activityChanged(); });
    takeLine(state);
}

} // namespace intake
