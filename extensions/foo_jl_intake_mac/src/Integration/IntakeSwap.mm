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
#include <strings.h>
#include <sys/stat.h>
#include <unordered_map>

namespace intake {

namespace {

struct SwapState {
    SwapState() {
        dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_autorelease_frequency(
            DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM);
        attr = dispatch_queue_attr_make_with_qos_class(attr, QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("com.foobar2000.intake.swap", attr);
    }
    // main
    bool stopped = false;
    bool running = false;
    // set once
    dispatch_queue_t queue = nil;
};

// Leaked on purpose (like the actions' state): a queue result may come back
// after on_quit.
SwapState &swapState() {
    static SwapState *state = new SwapState();
    return *state;
}

// One captured row through the queue.
struct PlannedRow {
    SwapRow row;
    SwapSkip skip = SwapSkip::None;
    std::string libraryPath;              // the spelling that exists
    std::vector<std::string> candidates;  // that path under each mount of the share, it first
};

struct SwapJob {
    t_size playlistIndex = SIZE_MAX;
    GUID playlistGuid = {};
    bool hasGuid = false;
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
        p.candidates = aliasMountPaths(mounts, found);
    }
}

// Main: the canonical path of `row`'s library file on the mount whose
// volume form is the row's, or "".
std::string canonicalFor(const PlannedRow &p) {
    const std::string wanted = canonicalVolumePrefix(p.row.path);
    if (wanted.empty()) return std::string();
    pfc::string8 canonical;
    for (const std::string &candidate : p.candidates) {
        try {
            filesystem::g_get_canonical_path(("file://" + candidate).c_str(), canonical);
        } catch (...) {
            continue;
        }
        const std::string out = canonical.c_str();
        if (sameVolumePrefix(canonicalVolumePrefix(out), wanted)) return out;
        logDebug("swap: " + candidate + " is " + out + " in foobar2000, not on the row's volume " + wanted);
    }
    return std::string();
}

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
    t_size playlist = SIZE_MAX;
    if (job->hasGuid) {
        auto v5 = playlist_manager_v5::tryGet();
        if (v5.is_valid()) playlist = v5->find_playlist_by_guid(job->playlistGuid);
    } else if (job->playlistIndex < pm->get_playlist_count()) {
        playlist = job->playlistIndex;
    }
    if (playlist == SIZE_MAX || playlist >= pm->get_playlist_count()) {
        skipAll(SwapSkip::PlaylistGone, "the playlist was closed");
        finish(*job, result);
        return;
    }
    result.playlist = playlist;
    if (pm->playlist_lock_get_filter_mask(playlist) & playlist_lock::filter_replace) {
        result.playlistLocked = true;
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
        const std::string canonical = canonicalFor(p);
        if (canonical.empty()) {
            for (size_t k = 0; k < indices.size(); k++) result.tally.skip(SwapSkip::NoMatchingMount);
            logDebug("swap: " + p.row.native + ": " + swapSkipText(SwapSkip::NoMatchingMount) + " for " +
                     p.libraryPath + " (the row is on " + canonicalVolumePrefix(p.row.path) + ")");
            continue;
        }
        const metadb_handle_ptr handle = db->handle_create(canonical.c_str(), p.row.subsong);
        for (t_size index : indices) replacements.push_back({index, handle, &p});
    }
    if (!replacements.empty()) {
        pm->playlist_undo_backup(playlist);
        for (const Replacement &r : replacements) {
            if (pm->playlist_replace_item(playlist, r.index, r.handle)) {
                result.tally.swapped++;
                logDebug("swap: row " + std::to_string(r.index) + ": " + r.row->row.native + " -> " +
                         r.handle->get_path());
            } else {
                result.tally.skip(SwapSkip::ReplaceRefused);
                logDebug("swap: row " + std::to_string(r.index) + ": " + swapSkipText(SwapSkip::ReplaceRefused));
            }
        }
    }
    finish(*job, result);
}

} // anonymous namespace

std::vector<SwapRow> swapRowsFromHandles(metadb_handle_list_cref handles, const std::unordered_set<std::string> &rootIds,
                                         const IntakeView &view, NativePathMenuBudget *budget) {
    std::vector<SwapRow> out;
    std::unordered_set<const metadb_handle *> seen;
    pfc::string8 native;
    ViewScratch scratch;
    for (t_size i = 0; i < handles.get_count(); i++) {
        @autoreleasepool {
            const metadb_handle_ptr handle = handles[i];
            if (!handle.is_valid() || !seen.insert(handle.get_ptr()).second) continue;
            const char *path = intakeNativePath(handle->get_path(), native, budget);
            if (path == nullptr) continue;
            const IntakeRecord *record = view.recordFor(path, scratch);
            if (record == nullptr || !rootIds.count(record->id)) continue;
            SwapRow row;
            row.handle = handle;
            row.path = handle->get_path();
            row.subsong = handle->get_subsong_index();
            row.native = stripFileScheme(path);
            row.rootId = record->id;
            out.push_back(std::move(row));
        }
    }
    return out;
}

std::vector<SwapRow> swapIncomeRows(t_size playlist, const std::unordered_set<std::string> &rootIds,
                                    const IntakeView &view, NativePathMenuBudget *budget, std::vector<t_size> *indices) {
    if (indices) indices->clear();
    auto pm = playlist_manager::get();
    if (playlist == SIZE_MAX || playlist >= pm->get_playlist_count()) return {};
    metadb_handle_list items;
    pm->playlist_get_all_items(playlist, items);
    std::vector<SwapRow> rows = swapRowsFromHandles(items, rootIds, view, budget);
    if (indices && !rows.empty()) {
        std::unordered_set<const metadb_handle *> wanted;
        for (const SwapRow &r : rows) wanted.insert(r.handle.get_ptr());
        for (t_size i = 0; i < items.get_count(); i++) {
            if (wanted.count(items[i].get_ptr())) indices->push_back(i);
        }
    }
    return rows;
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
    job->playlistIndex = playlist;
    auto v5 = playlist_manager_v5::tryGet();
    if (v5.is_valid()) {
        job->playlistGuid = v5->playlist_get_guid(playlist);
        job->hasGuid = !(job->playlistGuid == pfc::guid_null);
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
    dispatch_async(st.queue, ^{
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

std::vector<PlaylistRootRow> playlistRowsOfRoot(t_size playlist, const std::string &id, const IntakeView &view) {
    std::vector<PlaylistRootRow> out;
    auto pm = playlist_manager::get();
    if (playlist == SIZE_MAX || playlist >= pm->get_playlist_count()) return out;
    metadb_handle_list items;
    pm->playlist_get_all_items(playlist, items);
    pfc::string8 native;
    ViewScratch scratch;
    for (t_size i = 0; i < items.get_count(); i++) {
        @autoreleasepool {
            const metadb_handle_ptr handle = items[i];
            if (!handle.is_valid()) continue;
            const char *path = intakeNativePath(handle->get_path(), native);
            if (path == nullptr) continue;
            const IntakeRecord *income = view.recordFor(path, scratch);
            const IntakeRecord *library = income == nullptr ? view.libraryRecordFor(path, scratch) : nullptr;
            const IntakeRecord *record = income != nullptr ? income : library;
            if (record == nullptr || record->id != id) continue;
            PlaylistRootRow row;
            row.index = i;
            row.handle = handle;
            row.native = stripFileScheme(path);
            row.library = income == nullptr;
            out.push_back(std::move(row));
        }
    }
    return out;
}

void swapShutdown() {
    swapState().stopped = true;
}

} // namespace intake
