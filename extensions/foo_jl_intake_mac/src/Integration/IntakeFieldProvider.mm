//
//  IntakeFieldProvider.mm
//  foo_jl_intake
//
//  See IntakeFieldProvider.h. The values and the row mapping are Core
//  (IntakeFields, IntakeFieldState, IntakeVolumeTable) and unit-tested;
//  this file holds what needs the SDK: the service, the atomic state, the
//  main-thread publication and retirement, the throttled refresh over the
//  playlists, and the volume seed.
//

#import "../fb2k_sdk.h"

#include "IntakeFieldProvider.h"

#include "IntakeMounts.h"

#include "../Core/IntakeFieldState.h"
#include "../Core/IntakeFields.h"
#include "../Core/IntakeLog.h"
#include "../Core/IntakeSlowVolumeGuard.h"
#include "../Core/IntakeView.h"
#include "../Core/IntakeVolumeTable.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>
#include <strings.h>

namespace intake {

namespace {

using Clock = std::chrono::steady_clock;

// A replaced state is deleted this long after the swap: far beyond any
// process_field call (microseconds).
constexpr int64_t kRetireDelayNanos = 10 * static_cast<int64_t>(NSEC_PER_SEC);
// At most one refresh per this interval (SimPlaylist re-lays out, and v2
// regroups, on every refresh).
constexpr double kRefreshIntervalSeconds = 1.0;
// The first refresh after a quiet spell waits this long, so a burst of
// publishes (a load right after a seed) costs one refresh.
constexpr double kRefreshCoalesceSeconds = 0.25;

constexpr std::string_view kVolumesPrefix = "/Volumes/";

// Read by process_field on any thread; written on the main thread.
std::atomic<const FieldState *> g_state{nullptr};
// Set by the first process_field call; never cleared.
std::atomic<bool> g_used{false};
// fieldsShutdown: no publication, refresh, seed or deletion after it.
std::atomic<bool> g_quitting{false};

struct Fields {
    // Main thread only.
    bool started = false;
    std::shared_ptr<const IntakeView> view;  // null until the first publish
    std::shared_ptr<const VolumeTable> volumes = VolumeTable::empty();
    FieldDirtySet dirty;
    bool refreshScheduled = false;
    bool refreshRunning = false;
    bool everRefreshed = false;
    Clock::time_point lastRefresh;
    bool seedRunning = false;
    bool seedAgain = false;
    dispatch_queue_t seedQueue = nil;
    dispatch_queue_t filterQueue = nil;

    // Any thread (the decorate path), under learnMutex: volume ids with a
    // learn on its way to main, and ids whose rows failed the learn check
    // (forgotten at the next seed).
    std::mutex learnMutex;
    std::vector<std::string> learnPending;
    std::vector<std::string> learnRefused;

    Fields() {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_UTILITY, 0);
        seedQueue = dispatch_queue_create("com.foobar2000.intake.fields-seed", attr);
        filterQueue = dispatch_queue_create("com.foobar2000.intake.fields-refresh", attr);
    }
};

// Leaked on purpose, like the decorator provider's state: process_field
// and the decorate path may still run while static destructors do.
Fields &fields() {
    static Fields *state = new Fields();
    return *state;
}

bool containsId(const std::vector<std::string> &ids, std::string_view id) {
    for (const std::string &s : ids) {
        if (s.size() == id.size() && strncasecmp(s.data(), id.data(), id.size()) == 0) return true;
    }
    return false;
}

uint64_t microsSince(Clock::time_point start) {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() - start).count());
}

// --- process_field ---

bool evaluateField(t_uint32 index, metadb_handle *handle, titleformat_text_out *out) {
    if (index >= kIntakeFieldCount || handle == nullptr || out == nullptr) return false;
    // Sequentially consistent with swapState(): either that publish sees the
    // flag and diffs, or this load returns its state (or a later one).
    if (!g_used.load(std::memory_order_seq_cst)) g_used.store(true, std::memory_order_seq_cst);
    const FieldState *state = g_state.load(std::memory_order_seq_cst);
    if (state == nullptr || !state->showsValues()) return false;
    const char *path = handle->get_path();
    if (path == nullptr) return false;
    thread_local FieldScratch scratch;
    std::string_view value;
    if (!state->value(index, path, scratch, value)) return false;
    out->write(titleformat_inputtypes::meta, value.data(), value.size());
    return true;
}

class intake_field_provider : public metadb_display_field_provider_v2 {
public:
    t_uint32 get_field_count() override { return kIntakeFieldCount; }

    void get_field_name(t_uint32 index, pfc::string_base &out) override {
        const std::string_view name = intakeFieldName(index);
        out.set_string(name.data(), name.size());
    }

    bool process_field(t_uint32 index, metadb_handle *handle, titleformat_text_out *out) override {
        return evaluateField(index, handle, out);
    }

    bool process_field_v2(t_uint32 index, metadb_handle *handle, metadb_v2::rec_t const &rec,
                          titleformat_text_out *out) override {
        (void)rec;  // the values come from the path alone
        return evaluateField(index, handle, out);
    }
};

FB2K_SERVICE_FACTORY(intake_field_provider);

// --- publication (main thread) ---

void retire(const FieldState *old) {
    if (old == nullptr) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kRetireDelayNanos), dispatch_get_main_queue(), ^{
        if (g_quitting.load()) return;  // leaked at quit
        delete old;
    });
}

// Swaps in a state built from f.view and f.volumes and retires the old one.
// True when the fields are in use: the caller then adds its diff.
bool swapState(Fields &f) {
    const FieldState *next = new FieldState(f.view, f.volumes);
    const FieldState *old = g_state.exchange(next, std::memory_order_seq_cst);
    const bool used = g_used.load(std::memory_order_seq_cst);
    retire(old);
    return used;
}

void runRefresh(Fields &f);

void scheduleRefresh(Fields &f) {
    if (g_quitting.load() || f.refreshScheduled || f.refreshRunning || f.dirty.empty()) return;
    double delay = kRefreshCoalesceSeconds;
    if (f.everRefreshed) {
        const double since = std::chrono::duration<double>(Clock::now() - f.lastRefresh).count();
        delay = std::max(delay, kRefreshIntervalSeconds - since);
    }
    f.refreshScheduled = true;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       Fields &s = fields();
                       s.refreshScheduled = false;
                       runRefresh(s);
                   });
}

void publishView(Fields &f, std::shared_ptr<const IntakeView> view) {
    std::shared_ptr<const IntakeView> previous = std::move(f.view);
    f.view = std::move(view);
    if (!swapState(f)) return;
    addViewChanges(previous.get(), f.view.get(), f.dirty);
    scheduleRefresh(f);
}

void publishVolumes(Fields &f, std::shared_ptr<const VolumeTable> next) {
    if (next->sameAs(*f.volumes)) return;
    std::shared_ptr<const VolumeTable> previous = std::move(f.volumes);
    f.volumes = std::move(next);
    if (!swapState(f)) return;
    addVolumeChanges(*previous, *f.volumes, f.view.get(), f.dirty);
    scheduleRefresh(f);
}

// --- refresh ---

struct RefreshJob {
    FieldDirtySet dirty;
    std::shared_ptr<const VolumeTable> volumes;
    metadb_handle_list rows;     // every playlist's items; released on the refresh queue
    metadb_handle_list matched;  // the rows to refresh, each handle once
    size_t rowCount = 0;
    size_t matchedRows = 0;
    Clock::time_point started;
    uint64_t mainMicros = 0;
};

void finishRefresh(const std::shared_ptr<RefreshJob> &job) {
    Fields &f = fields();
    f.refreshRunning = false;
    if (g_quitting.load()) return;
    const Clock::time_point start = Clock::now();
    if (job->matched.get_count() > 0) metadb_io::get()->dispatch_refresh(job->matched);
    job->mainMicros += microsSince(start);
    f.lastRefresh = Clock::now();
    f.everRefreshed = true;
    if (isLogEnabled(LogLevel::Debug)) {
        char line[200];
        snprintf(line, sizeof line,
                 "fields: refreshed %zu of %zu playlist rows in %.1f ms (main thread %.1f ms, %zu root key(s))",
                 job->matchedRows, job->rowCount,
                 static_cast<double>(microsSince(job->started)) / 1000.0,
                 static_cast<double>(job->mainMicros) / 1000.0, job->dirty.keyCount());
        logDebug(line);
    }
    scheduleRefresh(f);  // what changed while this one ran
}

void runRefresh(Fields &f) {
    if (g_quitting.load() || f.refreshRunning || f.dirty.empty()) return;
    auto job = std::make_shared<RefreshJob>();
    job->started = Clock::now();
    job->dirty = std::move(f.dirty);
    f.dirty = FieldDirtySet();
    job->volumes = f.volumes;
    {
        auto pm = playlist_manager::get();
        const t_size count = pm->get_playlist_count();
        metadb_handle_list items;
        for (t_size i = 0; i < count; i++) {
            pm->playlist_get_all_items(i, items);  // clears `items` first
            job->rows.add_items(items);
        }
    }
    job->rowCount = job->rows.get_count();
    job->mainMicros = microsSince(job->started);
    f.refreshRunning = true;
    // The row tests (one path mapping per row, tens of milliseconds for
    // 80k rows) run off the main thread; get_path() is safe on any thread.
    dispatch_async(f.filterQueue, ^{
        FieldScratch scratch;
        std::unordered_set<const metadb_handle *> seen;
        const t_size count = job->rows.get_count();
        for (t_size i = 0; i < count; i++) {
            if (g_quitting.load(std::memory_order_relaxed)) break;
            const metadb_handle_ptr &handle = job->rows[i];
            if (!handle.is_valid()) continue;
            const char *path = handle->get_path();
            if (path == nullptr || !job->dirty.matches(path, *job->volumes, scratch)) continue;
            job->matchedRows++;
            if (seen.insert(handle.get_ptr()).second) job->matched.add_item(handle);
        }
        job->rows.remove_all();  // the references to every row, dropped here rather than on main
        dispatch_async(dispatch_get_main_queue(), ^{
            finishRefresh(job);
        });
    });
}

// --- volume seed ---

struct SeedResult {
    std::vector<VolumeEntry> entries;
    std::vector<std::string> mountPoints;  // every mount point, for mergeSeededVolumes
    size_t volumeMounts = 0;               // mounts under /Volumes
    uint64_t micros = 0;
};

bool underVolumes(const std::string &mountPoint) {
    return mountPoint.size() > kVolumesPrefix.size() &&
           strncasecmp(mountPoint.data(), kVolumesPrefix.data(), kVolumesPrefix.size()) == 0;
}

void noteSlowCall(const char *what, const std::string &argument, uint64_t micros) {
    if (!isSlowNativePathCall(micros)) return;
    char line[160];
    snprintf(line, sizeof line, "fields: %s took %llu ms for ", what,
             static_cast<unsigned long long>(micros / 1000));
    logInfo(std::string(line) + argument);
}

// The seed queue: two timed SDK calls per mount under /Volumes.
SeedResult seedOnQueue() {
    SeedResult r;
    const Clock::time_point start = Clock::now();
    const std::vector<MountEntry> mounts = readMountTable();
    for (const MountEntry &m : mounts) {
        r.mountPoints.push_back(m.mountPoint);
        if (!underVolumes(m.mountPoint)) continue;
        r.volumeMounts++;
        if (g_quitting.load()) continue;  // no SDK call during shutdown
        @autoreleasepool {
            const std::string root = m.mountPoint + "/";
            std::string canonical;
            Clock::time_point t = Clock::now();
            try {
                pfc::string8 out;
                filesystem::g_get_canonical_path(root.c_str(), out);
                canonical = out.c_str();
            } catch (...) {
                canonical.clear();
            }
            noteSlowCall("g_get_canonical_path", root, microsSince(t));
            const std::string_view uuid = volumeIdOfRoot(canonical);
            if (uuid.empty()) {
                logDebug("fields: " + root + " has no volume id (canonical form \"" + canonical + "\")");
                continue;
            }
            std::string native;
            bool converted = false;
            t = Clock::now();
            try {
                pfc::string8 out;
                converted = filesystem::g_get_native_path(canonical.c_str(), out);
                native = out.c_str();
            } catch (...) {
                converted = false;
            }
            noteSlowCall("g_get_native_path", canonical, microsSince(t));
            std::string volumeRoot = converted ? volumeRootFromNative(native) : std::string();
            if (volumeRoot.empty()) {
                logDebug("fields: " + canonical + " (from " + root + ") does not convert back to a native path");
                continue;
            }
            r.entries.push_back({std::string(uuid), std::move(volumeRoot)});
        }
    }
    r.micros = microsSince(start);
    return r;
}

void startSeed(Fields &f, std::string why) {
    f.seedRunning = true;
    dispatch_async(f.seedQueue, ^{
        auto result = std::make_shared<SeedResult>(seedOnQueue());
        dispatch_async(dispatch_get_main_queue(), ^{
            Fields &s = fields();
            s.seedRunning = false;
            if (g_quitting.load()) return;
            std::shared_ptr<const VolumeTable> next =
                mergeSeededVolumes(result->entries, *s.volumes, result->mountPoints);
            if (isLogEnabled(LogLevel::Debug)) {
                char head[160];
                snprintf(head, sizeof head, "fields: volume table (%s): %zu volume id(s), %zu mount(s) under /Volumes, %.1f ms: ",
                         why.c_str(), next->size(), result->volumeMounts, static_cast<double>(result->micros) / 1000.0);
                logDebug(std::string(head) + next->describe());
            }
            publishVolumes(s, std::move(next));
            if (s.seedAgain) {
                s.seedAgain = false;
                startSeed(s, "again");
            }
        });
    });
}

// --- learning from the decorate path ---

void learnOnMain(const std::string &id, const std::string &root) {
    Fields &f = fields();
    {
        std::lock_guard<std::mutex> lock(f.learnMutex);
        f.learnPending.erase(std::remove(f.learnPending.begin(), f.learnPending.end(), id), f.learnPending.end());
    }
    if (g_quitting.load() || f.volumes->rootFor(id) != nullptr) return;
    logDebug("fields: learned mac-volume " + id + " at " + root + " from a decorated row");
    publishVolumes(f, f.volumes->withVolume(id, root));
}

// Any thread; out of line from fieldsNoteNativePath (an unknown volume).
void learnVolume(std::string_view itemPath, std::string_view uuid, const char *native) {
    Fields &f = fields();
    const std::string id(uuid);
    const std::string root = learnedVolumeRoot(itemPath, native);
    {
        std::lock_guard<std::mutex> lock(f.learnMutex);
        if (containsId(f.learnPending, id) || containsId(f.learnRefused, id)) return;
        if (root.empty()) {
            f.learnRefused.push_back(id);
        } else {
            f.learnPending.push_back(id);
        }
    }
    if (root.empty()) {
        logDebug("fields: mac-volume " + id + " not learned: \"" + native +
                 "\" does not end with the row's path after the volume id");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        learnOnMain(id, root);
    });
}

} // anonymous namespace

void fieldsStart() {
    Fields &f = fields();
    if (f.started || g_quitting.load()) return;
    f.started = true;
    startSeed(f, "start");
}

void fieldsPublishView(std::shared_ptr<const IntakeView> view) {
    if (g_quitting.load()) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_quitting.load()) return;
        publishView(fields(), view);
    });
}

void fieldsReseedVolumes(const char *why) {
    Fields &f = fields();
    if (!f.started || g_quitting.load()) return;
    {
        std::lock_guard<std::mutex> lock(f.learnMutex);
        f.learnRefused.clear();
    }
    if (f.seedRunning) {
        f.seedAgain = true;
        return;
    }
    startSeed(f, why != nullptr ? why : "reseed");
}

void fieldsNoteNativePath(const char *itemPath, const char *native) {
    if (!g_used.load(std::memory_order_relaxed)) return;
    if (itemPath == nullptr || native == nullptr || itemPath == native || g_quitting.load(std::memory_order_relaxed)) {
        return;
    }
    std::string_view uuid;
    std::string_view rest;
    if (!splitMacVolumePath(itemPath, uuid, rest)) return;
    // A retired state lives 10 s after its swap: far beyond this lookup.
    const FieldState *state = g_state.load(std::memory_order_acquire);
    if (state != nullptr && state->volumes()->rootFor(uuid) != nullptr) return;
    learnVolume(itemPath, uuid, native);
}

void fieldsShutdown() {
    g_quitting.store(true);
}

} // namespace intake
