//
//  IntakeSwap.h
//  foo_jl_intake
//
//  "Swap to library paths" (doc 04 v1.2 "Context actions"; PLAN.md B9,
//  3.8): points playlist rows of placed roots at their library copies. A
//  playlist operation: no CLI command runs and no file is touched, so it
//  does not use the mutation lane and stays available while an execute
//  runs.
//
//  Flow (one swap at a time; a second request is refused with a reason):
//   1. Main thread, at the click: the playlist (the active one; its GUID
//      when playlist_manager_v5 serves it, else its index) and the rows,
//      captured by metadb handle with their path, subsong and native path
//      (IntakeNativePath), only rows that map to one of the qualifying roots
//      by their income path (IntakeView::recordFor). The host frees its
//      selection afterwards; the indices are never kept.
//   2. A private serial queue: the mount table (MNT_NOWAIT), each root's
//      sidecar files[] read afresh (IntakeSwapPlanner readPlacedRootFiles;
//      a read whose errno says the share is gone ends the reads), each row
//      planned (planSwap: its files[] entry, shadows and unlisted files
//      skipped, target_path + "/" + files[].path, the prefix pair; a target
//      outside a usable pair is used as is, logged at Debug), then the
//      library file stat'ed: the planned spelling first, then the other
//      Unicode form (SMB names may be NFD while sidecar paths are NFC),
//      under each mount of the share in turn (aliasMountPaths), keeping the
//      first that exists as a regular file. A stat whose errno says the
//      share is gone ends the stats: the remaining rows are skipped.
//   3. Main thread: the playlist is found again (by GUID, else the same
//      index). Gone, or locked against replacing items
//      (playlist_lock_get_filter_mask & playlist_lock::filter_replace):
//      nothing changes and the console line says why. Otherwise every
//      index that currently holds a captured handle is found (items may
//      have moved or gone meanwhile; every occurrence of the handle in that
//      playlist is swapped). Each library path is converted with
//      filesystem::g_get_canonical_path ("file://" + path) under each mount
//      of the share in turn, and the first whose volume form
//      (canonicalVolumePrefix: mac-volume://<UUID>/ or file://) equals the
//      row's own is used: no duplicate metadb entry
//      (docs/VOLUME_UUID_ISSUE.md, docs/intake-mac-paths.md). None: the row
//      is skipped ("no matching mount"). So a local income row is swapped
//      only to a local library file, and an SMB row only on the volume id
//      foobar2000 uses for it. Then playlist_undo_backup once, and
//      handle_create(canonical path, the row's subsong) plus
//      playlist_replace_item for each index.
//   4. One console line: "swap: N row(s) swapped to library paths, M
//      skipped (reasons with counts)" (Info; Error when nothing was swapped
//      and something was skipped); one Debug line per skipped row.
//  After on_quit (swapShutdown) results are dropped and nothing changes.
//
//  Thread-safety: main thread unless noted.
//

#pragma once

#import "../fb2k_sdk.h"

#include "../Core/IntakeSwapPlanner.h"

#include <functional>
#include <memory>
#include <string>
#include <unordered_set>
#include <vector>

namespace intake {

class IntakeView;
class NativePathMenuBudget;
struct IntakeRecord;

// One playlist row to swap, captured on the main thread.
struct SwapRow {
    metadb_handle_ptr handle;
    std::string path;      // handle->get_path(): foobar2000's form
    uint32_t subsong = 0;
    std::string native;    // its native path (IntakeNativePath)
    std::string rootId;
};

struct SwapResult {
    SwapTally tally;
    std::string line;  // the console line
    // The playlist as found at the end; SIZE_MAX when it was gone.
    t_size playlist = SIZE_MAX;
    bool playlistLocked = false;
};

// The rows of `handles` that map by income path to one of `rootIds`, each
// handle once, in order.
std::vector<SwapRow> swapRowsFromHandles(metadb_handle_list_cref handles, const std::unordered_set<std::string> &rootIds,
                                         const IntakeView &view, NativePathMenuBudget *budget);

// The rows of playlist `playlist` that map by income path to one of
// `rootIds`, each handle once, in playlist order. `indices` (optional)
// gets every playlist index such a row is at.
std::vector<SwapRow> swapIncomeRows(t_size playlist, const std::unordered_set<std::string> &rootIds,
                                    const IntakeView &view, NativePathMenuBudget *budget,
                                    std::vector<t_size> *indices = nullptr);

// Starts the swap of `rows` in playlist `playlist` (see the top of this
// file). False, with `why`, when it cannot start (another swap is running,
// quit started, no row). `done` runs once on the main thread after the
// console line, never after on_quit.
bool swapStart(t_size playlist, std::vector<SwapRow> rows, std::shared_ptr<const IntakeView> view,
               LibraryPrefix prefix, std::function<void(const SwapResult &result)> done, std::string &why);

// A swap is running (its queue part or its apply).
bool swapRunning();

// The sidecar files of `records`, read afresh on the swap queue
// (readPlacedRootFiles); `done` gets them on the main thread, in order,
// never after on_quit.
struct PlacedFilesReply {
    std::string id;
    bool ok = false;
    PlacedRootFiles files;
    std::string error;
};
void swapReadPlacedFiles(std::vector<IntakeRecord> records,
                         std::function<void(std::vector<PlacedFilesReply> replies)> done);

// The test aid's `rows` step: the rows of `playlist` that belong to root
// `id`, by income path or through the library index.
struct PlaylistRootRow {
    t_size index = 0;
    metadb_handle_ptr handle;
    std::string native;
    bool library = false;  // through the library index
};
std::vector<PlaylistRootRow> playlistRowsOfRoot(t_size playlist, const std::string &id, const IntakeView &view);

// on_quit (actionsShutdown): later results are dropped.
void swapShutdown();

} // namespace intake
