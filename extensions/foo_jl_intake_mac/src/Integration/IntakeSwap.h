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
//      selection afterwards; the indices are never kept. Also the volume
//      forms the playlist's items use (canonicalVolumePrefix of each path:
//      mac-volume://<UUID>/ or file://).
//   2. A private serial queue: the mount table (MNT_NOWAIT), each root's
//      sidecar files[] read afresh (IntakeSwapPlanner readPlacedRootFiles;
//      a read whose errno says the share is gone ends the reads), each row
//      planned (planSwap: its files[] entry, shadows and unlisted files
//      skipped, target_path + "/" + files[].path, the prefix pair; a target
//      outside a usable pair is used as is, logged at Debug), then the
//      library file stat'ed: the planned spelling first, then the other
//      Unicode form (SMB names may be NFD while sidecar paths are NFC),
//      under each mount of the share in turn (aliasMountPaths), the first
//      regular file found; then that spelling under every other mount of
//      the share is stat'ed too, and only the mounts where it exists stay
//      candidates (a mount whose stat says the share is gone is not stat'ed
//      again in this swap). A stat whose errno says the share is gone ends
//      the first stats: the remaining rows are skipped.
//   3. Main thread: the playlist is found again (by GUID, else the same
//      index). Gone, or locked against replacing items
//      (playlist_lock_get_filter_mask & playlist_lock::filter_replace):
//      nothing changes and the console line says why. Otherwise every
//      index that currently holds a captured handle is found (items may
//      have moved or gone meanwhile; every occurrence of the handle in that
//      playlist is swapped). The mount is chosen by its volume form
//      (filesystem::g_get_canonical_path of a file under it, once per mount
//      point per swap; IntakeSwapPlanner chooseCanonicalCandidate): one the
//      playlist's items already use, else the one whose form foobar2000
//      resolves back to that mount (g_get_native_path). So no duplicate
//      metadb entry (docs/VOLUME_UUID_ISSUE.md, docs/intake-mac-paths.md),
//      and the income row's own volume does not matter (local income and a
//      library on a share is the usual case). None: the row is skipped ("no
//      matching mount"). The chosen file is converted with
//      g_get_canonical_path; every SDK call here is timed, and once they
//      add up to 200 ms the remaining rows are skipped ("path conversion
//      too slow", one Info line). Then playlist_undo_backup once, and
//      handle_create(canonical path, the row's subsong) plus
//      playlist_replace_item for each index.
//   4. One console line: "swap: N row(s) swapped to library paths, M
//      skipped (reasons with counts)" (Info; Error when nothing was swapped
//      and something was skipped); one Debug line per skipped row.
//  After on_quit (swapShutdown) results are dropped and nothing changes.
//
//  The Delete flow (IntakeActions) also counts, with incomeRowCensus, the
//  entries of every playlist that still point at income paths of its roots,
//  and reads sidecars with swapReadPlacedFiles on a queue of its own, so a
//  running swap's stats never hold up its confirmation.
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
};

// A playlist to find again later: by GUID when playlist_manager_v5 serves
// one, else by index.
struct PlaylistRef {
    t_size index = SIZE_MAX;
    GUID guid = {};
    bool hasGuid = false;
};

// `playlist` now (SIZE_MAX gives a ref that finds nothing).
PlaylistRef playlistRefFor(t_size playlist);

// Where `ref` is now, or SIZE_MAX when it is gone.
t_size findPlaylist(const PlaylistRef &ref);

// The rows of `handles` that map by income path to one of `rootIds`, each
// handle once, in order. `unchecked` (optional) gets the number of handles
// whose mac-volume path was not converted (a slow volume, the budget): they
// may be income rows.
std::vector<SwapRow> swapRowsFromHandles(metadb_handle_list_cref handles, const std::unordered_set<std::string> &rootIds,
                                         const IntakeView &view, NativePathMenuBudget *budget,
                                         size_t *unchecked = nullptr);

// The rows of playlist `playlist` that map by income path to one of
// `rootIds`, each handle once, in playlist order. `unchecked` (optional)
// gets the number of entries whose mac-volume path was not converted.
std::vector<SwapRow> swapIncomeRows(t_size playlist, const std::unordered_set<std::string> &rootIds,
                                    const IntakeView &view, NativePathMenuBudget *budget,
                                    size_t *unchecked = nullptr);

// The entries of every playlist that still point at an income path of
// `rootIds` (main thread; one NativePathMenuBudget for all of them, so at
// most 3 slow conversions per volume, and a slow volume never stops another). Fail closed: an entry whose mac-volume path was
// not converted counts as unchecked, never as "no income row". An entry
// whose conversion was tried and failed (foobar2000 cannot resolve its
// volume, e.g. a stale volume id) is not counted: it already points at no
// reachable file, and Swap could not move it either.
struct IncomeRowCensus {
    std::vector<SwapRow> rows;           // each handle once: `first`'s rows, then the other playlists' in order
    std::vector<size_t> entries;         // per row: its entries, every playlist
    std::vector<PlaylistRef> playlists;  // the playlists holding income entries, `first` first
    size_t total = 0;                    // income entries, every playlist
    size_t inFirst = 0;                  // of them, in `first`
    size_t unchecked = 0;                // entries not converted, every playlist
};
IncomeRowCensus incomeRowCensus(const std::unordered_set<std::string> &rootIds, const IntakeView &view,
                                const PlaylistRef &first);

// Starts the swap of `rows` in playlist `playlist` (see the top of this
// file). False, with `why`, when it cannot start (another swap is running,
// quit started, no row). `done` runs once on the main thread after the
// console line, never after on_quit.
bool swapStart(t_size playlist, std::vector<SwapRow> rows, std::shared_ptr<const IntakeView> view,
               LibraryPrefix prefix, std::function<void(const SwapResult &result)> done, std::string &why);

// A swap is running (its queue part or its apply).
bool swapRunning();

// The sidecar files of `records`, read afresh on a serial queue of their
// own (readPlacedRootFiles; not the swap's queue); `done` gets them on the
// main thread, in order, never after on_quit.
struct PlacedFilesReply {
    std::string id;
    bool ok = false;
    PlacedRootFiles files;
    std::string error;
};
void swapReadPlacedFiles(std::vector<IntakeRecord> records,
                         std::function<void(std::vector<PlacedFilesReply> replies)> done);

// on_quit (actionsShutdown): later results are dropped.
void swapShutdown();

} // namespace intake
