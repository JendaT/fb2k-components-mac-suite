//
//  IntakeSwap.mm
//  foo_jl_intake
//
//  See IntakeSwap.h. Threading: SwapState's main fields are touched on the
//  main thread only; the queue reads sidecars, the mount table and stats,
//  and hands its result back with dispatch_async(main).
//

#import "../fb2k_sdk.h"

#include "IntakeSwap.h"

#include "IntakeMounts.h"
#include "IntakeNativePath.h"

#include "../Core/IntakeLog.h"
#include "../Core/IntakeSidecarMembers.h"
#include "../Core/IntakeSlowVolumeGuard.h"
#include "../Core/IntakeView.h"

#include <cerrno>
#include <chrono>
#include <strings.h>
#include <sys/stat.h>
#include <unordered_map>
#include <unordered_set>

namespace intake {

namespace {

// The main thread's allowance for one swap's SDK path conversions (step 3).
constexpr uint64_t kConvertBudgetMicros = 200000;

struct SwapState {
    SwapState() {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("com.foobar2000.intake.swap", attr);
        readQueue = dispatch_queue_create("com.foobar2000.intake.swap-read", attr);
    }
    // main
    bool stopped = false;
    bool running = false;
    // set once
    dispatch_queue_t queue = nil;      // the swap's reads and stats
    dispatch_queue_t readQueue = nil;  // swapReadPlacedFiles (the Delete confirmation)
};

// Leaked on purpose (like the actions' state): a queue result may come back
// after on_quit.
SwapState &swapState() {
    static SwapState *state = new SwapState();
    return *state;
}

// A library file that exists, and the mount point it is under.
struct MountedPath {
    std::string path;
    std::string mount;  // owningMountPoint
};

// One captured row through the queue.
struct PlannedRow {
    SwapRow row;
    SwapSkip skip = SwapSkip::None;
    std::string libraryPath;               // the spelling found first
    std::vector<MountedPath> candidates;   // that spelling under each mount of the share where it exists, it first
};

struct SwapJob {
    PlaylistRef playlist;
    std::vector<std::string> playlistForms;  // the volume forms of the playlist's items at the click
    std::vector<PlannedRow> rows;
    std::shared_ptr<const IntakeView> view;
    LibraryPrefix prefix;
    std::unordered_map<std::string, IntakeRecord> records;  // the qualifying roots, by id
    std::function<void(const SwapResult &)> done;
};

std::string stripFileScheme(const std::string &path) {
    if (path.size() >= 7 && strncasecmp(path.c_str(), "file://", 7) == 0) return path.substr(7);
    return path;
}

bool qualifies(const IntakeRecord &r) {
    return r.status == IntakeStatus::Placed && r.hasPlaced && r.placedVerified;
}

// Queue: steps 2 of IntakeSwap.h.
void planOnQueue(SwapJob &job) {
    const std::vector<MountEntry> mounts = readMountTable();
    std::unordered_map<std::string, PlacedRootFiles> files;
    std::unordered_map<std::string, std::string> unreadable;  // id -> why
    bool shareGone = false;
    for (const auto &entry : job.records) {
        if (shareGone) {
            unreadable[entry.first] = "the share stopped answering";
            continue;
        }
        PlacedRootFiles placed;
        std::string error;
        int err = 0;
        if (readPlacedRootFiles(entry.second, posixSidecarFileAccess(), placed, error, &err)) {
            files.emplace(entry.first, std::move(placed));
        } else {
            unreadable[entry.first] = error;
            logInfo("swap: " + entry.first + ": " + error);
            if (isShareUnreachableError(err)) shareGone = true;
        }
    }

    ViewScratch scratch;
    std::string key;
    bool libraryGone = false;
    std::unordered_set<std::string> deadMounts;  // alias mounts whose stat said the share is gone
    for (PlannedRow &p : job.rows) {
        auto rec = job.records.find(p.row.rootId);
        if (rec == job.records.end()) {
            p.skip = SwapSkip::NotPlaced;
            continue;
        }
        auto f = files.find(p.row.rootId);
        if (f == files.end()) {
            p.skip = SwapSkip::SidecarUnreadable;
            continue;
        }
        if (!job.view->matchKey(p.row.native, scratch, key)) {
            p.skip = SwapSkip::NotInSidecar;
            continue;
        }
        const SwapPlan plan = planSwap(f->second, key, job.prefix);
        if (plan.skip != SwapSkip::None) {
            p.skip = plan.skip;
            continue;
        }
        if (plan.rewrite == PrefixRewrite::OutsidePair) {
            logDebug("swap: " + plan.libraryPath + " lies outside the prefix pair " + job.prefix.from +
                     " -> " + job.prefix.to + "; used as is");
        }
        if (libraryGone) {
            p.skip = SwapSkip::ShareUnreachable;
            continue;
        }
        // The planned spelling, then the other Unicode form, under each
        // mount of the share; the first regular file wins.
        std::string found;
        for (const std::string &candidate : aliasMountPaths(mounts, plan.libraryPath)) {
            for (int form = 0; form < 2 && found.empty() && !libraryGone; form++) {
                const std::string path = form == 0 ? candidate : otherNormalizationForm(candidate);
                if (path.empty()) continue;
                struct stat st;
                if (::stat(path.c_str(), &st) == 0) {
                    if (S_ISREG(st.st_mode)) found = path;
                } else if (isShareUnreachableError(errno)) {
                    libraryGone = true;
                }
            }
            if (!found.empty() || libraryGone) break;
        }
        if (found.empty()) {
            p.skip = libraryGone ? SwapSkip::ShareUnreachable : SwapSkip::LibraryMissing;
            if (!libraryGone) logDebug("swap: no library file at " + plan.libraryPath);
            continue;
        }
        p.libraryPath = found;
        // That spelling under every other mount of the share: only the
        // mounts where it exists stay candidates.
        for (const std::string &path : aliasMountPaths(mounts, found)) {
            const std::string mount = owningMountPoint(mounts, path);
            if (path != found) {
                if (deadMounts.count(mount)) continue;
                struct stat st;
                if (::stat(path.c_str(), &st) != 0) {
                    if (isShareUnreachableError(errno)) deadMounts.insert(mount);
                    continue;
                }
                if (!S_ISREG(st.st_mode)) continue;
            }
            p.candidates.push_back({path, mount});
        }
    }
}

// Main: step 3's conversions for one swap. Each mount's volume form is
// worked out once (g_get_canonical_path of the first file seen under it,
// then g_get_native_path of that back); every SDK call is timed and the
// total kept under kConvertBudgetMicros.
class SwapConverter {
public:
    explicit SwapConverter(const std::vector<std::string> &playlistForms) : playlistForms_(playlistForms) {}

    // The canonical path `p` is swapped to, or "" with `skip` set.
    std::string canonicalFor(const PlannedRow &p, SwapSkip &skip) {
        if (spent()) {
            skip = SwapSkip::SlowConversion;
            return std::string();
        }
        std::vector<CanonicalCandidate> candidates;
        for (const MountedPath &m : p.candidates) {
            const Form &f = formOf(m);
            CanonicalCandidate c;
            c.path = m.path;
            c.form = f.form;
            c.roundTrips = f.roundTrips;
            candidates.push_back(std::move(c));
        }
        const long pick = chooseCanonicalCandidate(candidates, playlistForms_);
        if (pick < 0) {
            skip = spent() ? SwapSkip::SlowConversion : SwapSkip::NoMatchingMount;
            if (skip == SwapSkip::NoMatchingMount) {
                std::string seen;
                for (const CanonicalCandidate &c : candidates) {
                    seen += (seen.empty() ? "" : ", ") + c.path + " is " +
                            (c.form.empty() ? std::string("not converted") : c.form) +
                            (c.roundTrips ? "" : " (resolved to another mount)");
                }
                logDebug("swap: no playlist item uses a volume form of " + p.libraryPath + " and none maps back to its mount: " +
                         seen);
            }
            return std::string();
        }
        const CanonicalCandidate &chosen = candidates[static_cast<size_t>(pick)];
        std::string out;
        auto cached = canonical_.find(chosen.path);
        if (cached != canonical_.end()) {
            out = cached->second;
        } else if (spent()) {
            skip = SwapSkip::SlowConversion;
            return std::string();
        } else {
            out = convert(chosen.path);
        }
        if (!sameVolumePrefix(canonicalVolumePrefix(out), chosen.form)) {
            skip = spent() ? SwapSkip::SlowConversion : SwapSkip::NoMatchingMount;
            logDebug("swap: " + chosen.path + " converted to \"" + out + "\", not on " + chosen.form);
            return std::string();
        }
        if (!hasVolumeForm(playlistForms_, chosen.form)) {
            logDebug("swap: no playlist item is on " + chosen.form + "; " + chosen.path +
                     " uses it, the form foobar2000 resolves to its mount");
        }
        return out;
    }

    bool spent() const { return micros_ > kConvertBudgetMicros; }

private:
    struct Form {
        std::string form;
        bool roundTrips = false;
    };

    // Timed: g_get_canonical_path("file://" + path), "" when it threw.
    std::string convert(const std::string &path) {
        const auto start = std::chrono::steady_clock::now();
        std::string out;
        try {
            pfc::string8 canonical;
            filesystem::g_get_canonical_path(("file://" + path).c_str(), canonical);
            out = canonical.c_str();
        } catch (...) {
            out.clear();
        }
        note(start);
        return out;
    }

    // Timed: g_get_native_path(canonical) lies under `mount`.
    bool nativeUnder(const std::string &canonical, const std::string &mount) {
        const auto start = std::chrono::steady_clock::now();
        bool under = false;
        try {
            pfc::string8 native;
            under = filesystem::g_get_native_path(canonical.c_str(), native) &&
                    pathUnderMountPoint(native.c_str(), mount);
        } catch (...) {
            under = false;
        }
        note(start);
        return under;
    }

    void note(std::chrono::steady_clock::time_point start) {
        micros_ += static_cast<uint64_t>(
            std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - start).count());
    }

    // The volume form of `m`'s mount, worked out from `m.path` the first
    // time (no form once the budget is spent).
    const Form &formOf(const MountedPath &m) {
        auto known = forms_.find(m.mount);
        if (known != forms_.end()) return known->second;
        Form f;
        if (!spent()) {
            const std::string canonical = convert(m.path);
            canonical_[m.path] = canonical;
            f.form = canonicalVolumePrefix(canonical);
            if (!f.form.empty() && !spent()) f.roundTrips = nativeUnder(canonical, m.mount);
        }
        return forms_.emplace(m.mount, std::move(f)).first->second;
    }

    const std::vector<std::string> &playlistForms_;
    std::unordered_map<std::string, Form> forms_;           // mount point -> its form
    std::unordered_map<std::string, std::string> canonical_;  // path -> canonical, from formOf
    uint64_t micros_ = 0;
};

void finish(SwapJob &job, SwapResult &result) {
    SwapState &st = swapState();
    st.running = false;
    result.line = swapResultLine(result.tally);
    if (result.tally.swapped == 0 && result.tally.skippedTotal() > 0) {
        logError(result.line);
    } else {
        logInfo(result.line);
    }
    if (job.done) job.done(result);
}

// Main: step 3 of IntakeSwap.h.
void applyOnMain(std::shared_ptr<SwapJob> job) {
    SwapState &st = swapState();
    if (st.stopped) {
        st.running = false;
        return;
    }
    SwapResult result;
    auto skipAll = [&](SwapSkip reason, const std::string &why) {
        for (const PlannedRow &p : job->rows) {
            const SwapSkip shown = p.skip == SwapSkip::None ? reason : p.skip;
            result.tally.skip(shown);
            logDebug("swap: " + p.row.native + ": " + swapSkipText(shown) + (why.empty() ? "" : " (" + why + ")"));
        }
    };

    auto pm = playlist_manager::get();
    const t_size playlist = findPlaylist(job->playlist);
    if (playlist == SIZE_MAX) {
        skipAll(SwapSkip::PlaylistGone, "the playlist was closed");
        finish(*job, result);
        return;
    }
    if (pm->playlist_lock_get_filter_mask(playlist) & playlist_lock::filter_replace) {
        pfc::string8 name;
        pm->playlist_get_name(playlist, name);
        skipAll(SwapSkip::PlaylistLocked, std::string("\"") + name.c_str() + "\" does not allow replacing items");
        finish(*job, result);
        return;
    }

    // Where each captured handle is now.
    std::unordered_map<const metadb_handle *, std::vector<t_size>> where;
    for (const PlannedRow &p : job->rows) {
        if (p.skip == SwapSkip::None) where[p.row.handle.get_ptr()];
    }
    metadb_handle_list items;
    pm->playlist_get_all_items(playlist, items);
    for (t_size i = 0; i < items.get_count(); i++) {
        auto found = where.find(items[i].get_ptr());
        if (found != where.end()) found->second.push_back(i);
    }

    struct Replacement {
        t_size index;
        metadb_handle_ptr handle;
        const PlannedRow *row;
    };
    std::vector<Replacement> replacements;
    auto db = metadb::get();
    SwapConverter converter(job->playlistForms);
    for (const PlannedRow &p : job->rows) {
        if (p.skip != SwapSkip::None) {
            result.tally.skip(p.skip);
            logDebug("swap: " + p.row.native + ": " + swapSkipText(p.skip));
            continue;
        }
        const std::vector<t_size> &indices = where[p.row.handle.get_ptr()];
        if (indices.empty()) {
            result.tally.skip(SwapSkip::RowGone);
            logDebug("swap: " + p.row.native + ": " + swapSkipText(SwapSkip::RowGone));
            continue;
        }
        SwapSkip why = SwapSkip::None;
        const std::string canonical = converter.canonicalFor(p, why);
        if (canonical.empty()) {
            for (size_t k = 0; k < indices.size(); k++) result.tally.skip(why);
            logDebug("swap: " + p.row.native + ": " + swapSkipText(why) + " for " + p.libraryPath);
            continue;
        }
        const metadb_handle_ptr handle = db->handle_create(canonical.c_str(), p.row.subsong);
        for (t_size index : indices) replacements.push_back({index, handle, &p});
    }
    if (result.tally.skippedFor(SwapSkip::SlowConversion) > 0) {
        logInfo("swap: the path conversions took over " + std::to_string(kConvertBudgetMicros / 1000) + " ms; " +
                std::to_string(result.tally.skippedFor(SwapSkip::SlowConversion)) + " row(s) left as they are");
    }
    if (!replacements.empty()) {
        pm->playlist_undo_backup(playlist);
        // A library copy that nothing in foobar2000 has read yet gets a
        // handle with no info: SimPlaylist then groups its rows under an
        // empty header until playback reads the tags (UAT check 4). Those
        // handles are read below, in the background.
        metadb_handle_list unread;
        std::unordered_set<const metadb_handle *> seen;
        for (const Replacement &r : replacements) {
            if (pm->playlist_replace_item(playlist, r.index, r.handle)) {
                result.tally.swapped++;
                logDebug("swap: row " + std::to_string(r.index) + ": " + r.row->row.native + " -> " +
                         r.handle->get_path());
                metadb_info_container::ptr info;
                if (seen.insert(r.handle.get_ptr()).second && !r.handle->get_info_ref(info)) unread.add_item(r.handle);
            } else {
                result.tally.skip(SwapSkip::ReplaceRefused);
                logDebug("swap: row " + std::to_string(r.index) + ": " + swapSkipText(SwapSkip::ReplaceRefused));
            }
        }
        if (unread.get_count() > 0) {
            // No dialog, no error popups; foobar2000 reads on its own
            // threads, so neither the main thread nor the decorate path
            // waits on the library volume.
            const size_t count = unread.get_count();
            logDebug("swap: reading tags of " + std::to_string(count) + " swapped file(s) with no info");
            metadb_io_v2::get()->load_info_async(
                unread, metadb_io::load_info_default, core_api::get_main_window(),
                metadb_io_v2::op_flag_background | metadb_io_v2::op_flag_delay_ui | metadb_io_v2::op_flag_no_errors,
                fb2k::makeCompletionNotify([count](unsigned code) {
                    logDebug("swap: tags read for " + std::to_string(count) + " file(s) (" +
                             (code == metadb_io::load_info_success   ? "success"
                              : code == metadb_io::load_info_aborted ? "aborted"
                                                                     : "errors") +
                             ")");
                }));
        }
    }
    finish(*job, result);
}

} // anonymous namespace

PlaylistRef playlistRefFor(t_size playlist) {
    PlaylistRef ref;
    auto pm = playlist_manager::get();
    if (playlist == SIZE_MAX || playlist >= pm->get_playlist_count()) return ref;
    ref.index = playlist;
    auto v5 = playlist_manager_v5::tryGet();
    if (v5.is_valid()) {
        ref.guid = v5->playlist_get_guid(playlist);
        ref.hasGuid = !(ref.guid == pfc::guid_null);
    }
    return ref;
}

t_size findPlaylist(const PlaylistRef &ref) {
    auto pm = playlist_manager::get();
    t_size playlist = SIZE_MAX;
    if (ref.hasGuid) {
        auto v5 = playlist_manager_v5::tryGet();
        if (v5.is_valid()) playlist = v5->find_playlist_by_guid(ref.guid);
    } else {
        playlist = ref.index;
    }
    return playlist < pm->get_playlist_count() ? playlist : SIZE_MAX;
}

namespace {

// What one handle maps to.
enum class RowMatch { None, Income, Unchecked };

RowMatch matchRow(const metadb_handle_ptr &handle, const std::unordered_set<std::string> &rootIds,
                  const IntakeView &view, NativePathMenuBudget *budget, pfc::string8 &native, ViewScratch &scratch,
                  SwapRow &out) {
    bool refused = false;
    const char *path = intakeNativePath(handle->get_path(), native, budget, &refused);
    if (path == nullptr) return refused ? RowMatch::Unchecked : RowMatch::None;
    const IntakeRecord *record = view.recordFor(path, scratch);
    if (record == nullptr || !rootIds.count(record->id)) return RowMatch::None;
    out.handle = handle;
    out.path = handle->get_path();
    out.subsong = handle->get_subsong_index();
    out.native = stripFileScheme(path);
    out.rootId = record->id;
    return RowMatch::Income;
}

// One playlist's income rows: each handle once, with its entries.
struct PlaylistScan {
    std::vector<SwapRow> rows;
    std::vector<size_t> entries;  // per row
    std::vector<t_size> indices;  // every income entry, ascending
    size_t unchecked = 0;         // entries not converted
};

PlaylistScan scanPlaylist(t_size playlist, const std::unordered_set<std::string> &rootIds, const IntakeView &view,
                          NativePathMenuBudget *budget) {
    PlaylistScan out;
    auto pm = playlist_manager::get();
    if (playlist == SIZE_MAX || playlist >= pm->get_playlist_count()) return out;
    metadb_handle_list items;
    pm->playlist_get_all_items(playlist, items);
    // Per handle: the row index, or -1 (no match), or -2 (unchecked).
    std::unordered_map<const metadb_handle *, long> seen;
    pfc::string8 native;
    ViewScratch scratch;
    for (t_size i = 0; i < items.get_count(); i++) {
        @autoreleasepool {
            const metadb_handle_ptr handle = items[i];
            if (!handle.is_valid()) continue;
            auto known = seen.find(handle.get_ptr());
            long state;
            if (known != seen.end()) {
                state = known->second;
            } else {
                SwapRow row;
                const RowMatch match = matchRow(handle, rootIds, view, budget, native, scratch, row);
                if (match == RowMatch::Income) {
                    state = static_cast<long>(out.rows.size());
                    out.rows.push_back(std::move(row));
                    out.entries.push_back(0);
                } else {
                    state = match == RowMatch::Unchecked ? -2 : -1;
                }
                seen.emplace(handle.get_ptr(), state);
            }
            if (state >= 0) {
                out.entries[static_cast<size_t>(state)]++;
                out.indices.push_back(i);
            } else if (state == -2) {
                out.unchecked++;
            }
        }
    }
    return out;
}

} // anonymous namespace

std::vector<SwapRow> swapRowsFromHandles(metadb_handle_list_cref handles, const std::unordered_set<std::string> &rootIds,
                                         const IntakeView &view, NativePathMenuBudget *budget, size_t *unchecked) {
    std::vector<SwapRow> out;
    if (unchecked) *unchecked = 0;
    std::unordered_set<const metadb_handle *> seen;
    pfc::string8 native;
    ViewScratch scratch;
    for (t_size i = 0; i < handles.get_count(); i++) {
        @autoreleasepool {
            const metadb_handle_ptr handle = handles[i];
            if (!handle.is_valid() || !seen.insert(handle.get_ptr()).second) continue;
            SwapRow row;
            const RowMatch match = matchRow(handle, rootIds, view, budget, native, scratch, row);
            if (match == RowMatch::Income) {
                out.push_back(std::move(row));
            } else if (match == RowMatch::Unchecked && unchecked) {
                (*unchecked)++;
            }
        }
    }
    return out;
}

std::vector<SwapRow> swapIncomeRows(t_size playlist, const std::unordered_set<std::string> &rootIds,
                                    const IntakeView &view, NativePathMenuBudget *budget, size_t *unchecked) {
    PlaylistScan scan = scanPlaylist(playlist, rootIds, view, budget);
    if (unchecked) *unchecked = scan.unchecked;
    return std::move(scan.rows);
}

IncomeRowCensus incomeRowCensus(const std::unordered_set<std::string> &rootIds, const IntakeView &view,
                                const PlaylistRef &first) {
    IncomeRowCensus out;
    auto pm = playlist_manager::get();
    const t_size count = pm->get_playlist_count();
    const t_size firstIndex = findPlaylist(first);
    std::vector<t_size> order;
    if (firstIndex != SIZE_MAX) order.push_back(firstIndex);
    for (t_size p = 0; p < count; p++) {
        if (p != firstIndex) order.push_back(p);
    }
    NativePathMenuBudget budget;
    std::unordered_map<const metadb_handle *, size_t> rowOf;
    for (t_size p : order) {
        PlaylistScan scan = scanPlaylist(p, rootIds, view, &budget);
        out.unchecked += scan.unchecked;
        if (scan.indices.empty()) continue;
        out.playlists.push_back(playlistRefFor(p));
        out.total += scan.indices.size();
        if (p == firstIndex) out.inFirst = scan.indices.size();
        for (size_t r = 0; r < scan.rows.size(); r++) {
            auto known = rowOf.find(scan.rows[r].handle.get_ptr());
            if (known != rowOf.end()) {
                out.entries[known->second] += scan.entries[r];
                continue;
            }
            rowOf.emplace(scan.rows[r].handle.get_ptr(), out.rows.size());
            out.rows.push_back(std::move(scan.rows[r]));
            out.entries.push_back(scan.entries[r]);
        }
    }
    return out;
}

bool swapStart(t_size playlist, std::vector<SwapRow> rows, std::shared_ptr<const IntakeView> view, LibraryPrefix prefix,
               std::function<void(const SwapResult &result)> done, std::string &why) {
    SwapState &st = swapState();
    if (st.stopped) {
        why = "intake is not running";
        return false;
    }
    if (st.running) {
        why = "another swap is still running";
        return false;
    }
    if (!view || rows.empty()) {
        why = "no row points at an income path of these roots";
        return false;
    }
    auto pm = playlist_manager::get();
    if (playlist == SIZE_MAX || playlist >= pm->get_playlist_count()) {
        why = "no active playlist";
        return false;
    }
    auto job = std::make_shared<SwapJob>();
    job->playlist = playlistRefFor(playlist);
    {
        metadb_handle_list items;
        pm->playlist_get_all_items(playlist, items);
        for (t_size i = 0; i < items.get_count(); i++) {
            if (items[i].is_valid()) noteVolumeForm(job->playlistForms, items[i]->get_path());
        }
    }
    for (SwapRow &row : rows) {
        if (!job->records.count(row.rootId)) {
            const IntakeRecord *record = view->snapshot().recordForId(row.rootId);
            if (record != nullptr && qualifies(*record)) job->records.emplace(row.rootId, *record);
        }
        PlannedRow planned;
        planned.row = std::move(row);
        job->rows.push_back(std::move(planned));
    }
    job->view = std::move(view);
    job->prefix = std::move(prefix);
    job->done = std::move(done);
    st.running = true;
    logInfo("swap: starting for " + std::to_string(job->rows.size()) + " row(s) of " +
            std::to_string(job->records.size()) + " root(s)");
    dispatch_async(st.queue, ^{
        planOnQueue(*job);
        dispatch_async(dispatch_get_main_queue(), ^{
            applyOnMain(job);
        });
    });
    return true;
}

bool swapRunning() {
    return swapState().running;
}

void swapReadPlacedFiles(std::vector<IntakeRecord> records,
                         std::function<void(std::vector<PlacedFilesReply> replies)> done) {
    SwapState &st = swapState();
    if (st.stopped) return;
    auto input = std::make_shared<std::vector<IntakeRecord>>(std::move(records));
    auto callback = std::make_shared<std::function<void(std::vector<PlacedFilesReply>)>>(std::move(done));
    dispatch_async(st.readQueue, ^{
        auto replies = std::make_shared<std::vector<PlacedFilesReply>>();
        bool shareGone = false;
        for (const IntakeRecord &record : *input) {
            PlacedFilesReply reply;
            reply.id = record.id;
            if (shareGone) {
                reply.error = "the share stopped answering";
            } else {
                int err = 0;
                reply.ok = readPlacedRootFiles(record, posixSidecarFileAccess(), reply.files, reply.error, &err);
                if (!reply.ok && isShareUnreachableError(err)) shareGone = true;
            }
            replies->push_back(std::move(reply));
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (swapState().stopped) return;
            if (*callback) (*callback)(std::move(*replies));
        });
    });
}

void swapShutdown() {
    swapState().stopped = true;
}

} // namespace intake
