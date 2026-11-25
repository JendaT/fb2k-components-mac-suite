//
//  IntakeActivityHub.mm
//  foo_jl_intake
//
//  See IntakeActivityHub.h. Everything in HubState is main-thread only,
//  except runsTracked, which the loader queue reads.
//

#import <Foundation/Foundation.h>

#include "IntakeActivityHub.h"

#include "IntakeDecoratorProvider.h"

#include "../Core/IntakeActionTable.h"
#include "../Core/IntakeRunProgress.h"
#include "../Core/IntakeView.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <unordered_map>

namespace intake {

namespace {

struct HubState {
    // main
    ActivityModel model;
    std::function<void()> onChange;
    bool stopped = false;              // after activityClear (quit)
    uint64_t expiryGeneration = 0;     // the expiry timer that may still act
    std::unordered_map<std::string, RunProgress> runs;  // by activity key
    // main writes, the loader queue reads
    std::atomic<bool> runsTracked{false};
};

// Leaked on purpose: hooks may run after on_quit.
HubState &hub() {
    static HubState *state = new HubState();
    return *state;
}

void notifyChanged();

// One dispatch_after at the model's next expiry (a result's 10 s or a
// running entry's deadline); an older one finds its generation stale and
// does nothing. On the wall clock (dispatch_walltime), the clock of
// activityNowMs: dispatch_time counts mach_absolute_time, which stops while
// the Mac sleeps, so a lid closed 2 s into a result's 10 s would keep the
// line for another 8 s after waking. A walltime timer fires on waking when
// its time passed during sleep. The price: a wall clock set back delays it
// by as much (rare; the next change re-arms it).
void scheduleExpiry() {
    HubState &h = hub();
    const uint64_t generation = ++h.expiryGeneration;
    if (h.stopped) return;
    const int64_t now = activityNowMs();
    const std::optional<int64_t> next = h.model.nextExpiry(now);
    if (!next) return;
    // A deadline already past: at once (1 ms).
    const int64_t delayMs = std::max<int64_t>(*next - now, 0) + 1;
    dispatch_after(dispatch_walltime(nullptr, delayMs * static_cast<int64_t>(NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
                       HubState &later = hub();
                       if (later.expiryGeneration != generation || later.stopped) return;
                       later.model.prune(activityNowMs());
                       notifyChanged();
                   });
}

void notifyChanged() {
    HubState &h = hub();
    scheduleExpiry();
    if (h.onChange) h.onChange();
}

void forgetRun(const std::string &key) {
    HubState &h = hub();
    h.runs.erase(key);
    h.runsTracked.store(!h.runs.empty(), std::memory_order_relaxed);
}

RunStatusLookup lookupIn(const IntakeView *view) {
    return [view](const std::string &id, IntakeStatus &status) {
        const IntakeRecord *record = view != nullptr ? view->snapshot().recordForId(id) : nullptr;
        if (record == nullptr) return false;
        status = record->status;
        return true;
    };
}

// The label of `id` in `view`, else in the current view (or its id).
std::string labelIn(const IntakeView *view, const std::string &id) {
    if (id.empty()) return std::string();
    if (const IntakeRecord *record = view != nullptr ? view->snapshot().recordForId(id) : nullptr) {
        return albumLabel(actionRootFor(*record));
    }
    return activityLabelFor(id);
}

// Main: one view against every tracked run.
void stepRuns(const std::shared_ptr<const IntakeView> &view) {
    HubState &h = hub();
    if (h.stopped || h.runs.empty() || !view) return;
    const RunStatusLookup lookup = lookupIn(view.get());
    bool changed = false;
    for (auto &entry : h.runs) {
        RunProgress &run = entry.second;
        if (!run.update(lookup)) continue;
        if (h.model.progress(entry.first, run.done(), run.total(), labelIn(view.get(), run.current()))) changed = true;
    }
    if (changed) notifyChanged();
}

} // anonymous namespace

const ActivityModel &activityModel() {
    return hub().model;
}

int64_t activityNowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

void activitySetChangeHandler(std::function<void()> handler) {
    hub().onChange = std::move(handler);
}

void activityBegin(const std::string &key, ActivityKind kind, size_t count, const std::string &firstLabel) {
    HubState &h = hub();
    if (h.stopped) return;
    h.model.begin(key, kind, count, firstLabel, activityNowMs());
    notifyChanged();
}

void activityBeginRun(const std::string &stem, CliCommand command, const std::vector<std::string> &ids,
                      const std::string &firstLabel) {
    HubState &h = hub();
    if (h.stopped) return;
    const std::string key = activityRunKey(stem);
    const bool resume = command == CliCommand::Resume;
    h.model.begin(key, resume ? ActivityKind::Resume : ActivityKind::Execute, ids.size(), firstLabel,
                  activityNowMs());
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    RunProgress run;
    run.start(ids, resume, lookupIn(view.get()));
    // An adopted run may be half done already.
    h.model.progress(key, run.done(), run.total(), labelIn(view.get(), run.current()));
    h.runs[key] = std::move(run);
    h.runsTracked.store(true, std::memory_order_relaxed);
    notifyChanged();
}

void activityDeadline(const std::string &key, int64_t afterMs, const ActivityResult &result) {
    HubState &h = hub();
    if (h.stopped) return;
    // The line does not change now: only the timer is re-armed.
    if (h.model.deadline(key, activityNowMs() + afterMs, result)) scheduleExpiry();
}

void activityRename(const std::string &key, ActivityKind kind, size_t count, const std::string &firstLabel) {
    HubState &h = hub();
    if (h.stopped) return;
    if (h.model.rename(key, kind, count, firstLabel)) notifyChanged();
}

void activityProgress(const std::string &key, uint32_t done, uint32_t total, const std::string &currentLabel) {
    HubState &h = hub();
    if (h.stopped) return;
    if (h.model.progress(key, done, total, currentLabel)) notifyChanged();
}

void activityEnd(const std::string &key, const ActivityResult &result, std::optional<size_t> count) {
    HubState &h = hub();
    if (h.stopped) return;
    forgetRun(key);
    if (h.model.end(key, result, activityNowMs(), count)) notifyChanged();
}

void activityClear() {
    HubState &h = hub();
    if (h.stopped) return;
    h.model.clear();
    h.runs.clear();
    h.runsTracked.store(false, std::memory_order_relaxed);
    h.stopped = true;
    h.expiryGeneration++;  // a pending expiry does nothing
    if (h.onChange) h.onChange();
}

void activityViewPublished(const std::shared_ptr<const IntakeView> &view) {
    if (!view || !hub().runsTracked.load(std::memory_order_relaxed)) return;
    std::shared_ptr<const IntakeView> published = view;
    dispatch_async(dispatch_get_main_queue(), ^{
        stepRuns(published);
    });
}

std::string activityLabelFor(const std::string &id, const std::string &rootPath) {
    const std::shared_ptr<const IntakeView> view = providerCurrentView();
    if (const IntakeRecord *record = view ? view->snapshot().recordForId(id) : nullptr) {
        return albumLabel(actionRootFor(*record));
    }
    ActionRoot root;
    root.id = id;
    root.rootPath = rootPath;
    return albumLabel(root);
}

} // namespace intake
