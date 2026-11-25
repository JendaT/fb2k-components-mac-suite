//
//  IntakeLoader.h
//  foo_jl_intake
//
//  Loads intake state into an IntakeView and publishes it (PLAN.md B3, 3.2,
//  3.3, 3.4). SDK-free, so the whole pipeline runs in the unit tests against
//  the mock CLI; Integration (IntakeService) only supplies the configuration,
//  the mount table reader and the publish target (the provider).
//
//  One load, on the loader's serial queue (also the read lane):
//   1. `version --json` (when not yet passed, after a failure, or on a
//      recheck): the integer schema gate (IntakeVersionGate), then `cli` and
//      `commands` into CliConfig (cliVersion, cliListsCommands) and into
//      the status (LoaderStatus::cliInfo, B6 feature detection);
//   2. `status --json` (Ok, or Partial: the subset that loaded, errors
//      logged): IntakeStatusModel. A Partial whose E_PARSE errors name
//      sidecars (a write in progress) keeps the last record of each root
//      they name (carryOverUnreadable, PLAN.md 3.5, risk 7) and retries
//      once 1 s later: one more load, listing those folders again, which
//      does not retry again if it meets E_PARSE once more (the writer's own
//      FSEvents event triggers the next load);
//   3. every root key through the mount aliases (IntakeMountAliases);
//   4. member lists (IntakeSidecarMembers), bounded by a deadline and a
//      cancel flag that shutdown() sets;
//   5. LoaderSettings::annotateRecords (B6: the per-root command errors);
//   6. IntakeSnapshot, published with invalidate-all on the first successful
//      load, after an inert state, and whenever it does not render like the
//      last one (rendersAlike, IntakeLoadPolicy). An unchanged load is still
//      published, without invalidation.
//  An empty CLI path is "not configured": nothing is spawned, one log line,
//  nothing renders, and it is not an error.
//  Failures follow loadFailureEffect / gateFailureEffect (doc 03 v1.2
//  "Inert state"): an inert view, or the last data kept with one log line.
//  A gate failure's inert view lasts while the gate fails: once `version`
//  passes again, a failed `status` shows the last load (Stale).
//
//  Income (B4): when the CLI lists `income` (cliSupportsCommand), a load
//  that ran `version` (the first load, reload(true), a retry after a
//  failed version) runs `income --json` between `version` and `status`. Its
//  folders feed the watch set. A failed income call is a per-command error:
//  one log line, the last good folder list is kept, and the load goes on
//  with `status` (never inert). While the last `income` call answered, a
//  root that is an income folder itself is left out of each load
//  (dropIncomeFolderRoots, IntakeLoadPolicy), with one Info line per root
//  per session; with income not offered or failed there is no guard.
//
//  Settings changes (B5, the preferences page through IntakeService):
//  reconfigure() replaces the CLI path, bun path, rules folder and
//  environment and starts over as a new loader would: a running load is
//  cancelled (its read-lane process killed) and whatever it still delivers
//  is discarded, the last load is forgotten (an empty view is published,
//  with invalidate-all when the shown view decorated anything), and a load
//  with `version` (and `income`) follows. An empty CLI path ends in
//  NotConfigured, with an empty watch set. setWatchFolders() replaces the watch_folders setting and
//  recomputes the watch set; nothing is reloaded (a new stream replays from
//  the last `status` call's event id, IntakeWatcher).
//
//  Triggers: reload() (init, a mount event, later Refresh, preferences and
//  the post-command refresh), reloadForChanges() (an FSEvents batch, B4)
//  and remount(), which re-reads the mount table and, when the aliases
//  changed, rebuilds the keys of the last load and publishes them, with
//  invalidate-all only when a row can decorate differently
//  (remountChangesRows). A reload requested while a load runs is coalesced
//  into one more load after it (the "reload again" flag), whatever its
//  trigger. Every load is one full `status --json`, never `--filter` (doc 03
//  gives filtered calls no cost guarantee).
//
//  Watch set (B4, IntakeWatchSet): after every load attempt and every
//  remount, the candidates (LoaderSettings::watchFolders, the income
//  folders, the parent of every root_path of the last good load) are
//  resolved and reduced on the loader queue (lstat/readlink only on local
//  paths, decided from the mount table, read again with MNT_NOWAIT right
//  before: a share that mounted during the load is not taken for a local
//  folder), and onWatchSet gets the stream paths only when they differ from
//  the last ones handed over. That fresh table decides local or network
//  only; the aliases change only where the share links are read too
//  (remount(), and with share links configured relink() and the start of
//  every load). With no CLI path
//  (NotConfigured) the set is empty: nothing could reload.
//  B12: every such update also pairs the income folders with that set's
//  spelling (IntakeAutoScan autoScanIncomes: what FSEvents reports for each)
//  into LoaderStatus::autoScanIncomes, before the load-finished handler
//  runs, so IntakeService hands them to the auto-scan with each load.
//
//  Event ids (IntakeWatcher): just before each `status` call the loader
//  takes LoaderSettings::currentEventId (FSEventsGetCurrentEventId in
//  production) and hands the latest such id over with every watch set, so a
//  new stream replays what changed since that call instead of costing a
//  load of its own. Every change before it is in that `status`, and every
//  relevant event after it either started a later load (with a later id)
//  or is still pending (replayed as well: at worst one more coalesced
//  load). restartWatch() (after a mount or unmount, following
//  remount() and reload(false)) replaces the stream with the same paths,
//  from the id of the reload's `status` when that call has already started
//  (none requested since it), else from now (that `status` still comes, and
//  sees what changed before it). It runs no `status` of its own.
//
//  Incremental member lists (B4, IntakeSidecarMembers MemberReuse): a load
//  started only by reloadForChanges() lists again just the directories its
//  batches named (mapped to match keys through the watch set and the mount
//  aliases); other directories keep the previous classification. Any other
//  trigger, a remount, a rescan batch, a batch directory that maps to no
//  watched folder, or a member pass that stopped early makes the next load
//  list everything as before. Directories named by a load that failed
//  before its member pass carry over to the next load.
//
//  Library index (B9, IntakeLibraryIndex): after the member pass, every root
//  that is placed with placed.verified and a target path has its sidecar
//  files[] read (IntakeSwapPlanner readPlacedRootFiles, through
//  LoaderSettings::files, bounded by the same deadline and cancel flag; a
//  failure that says the share is gone ends the reads, and a member pass
//  that stopped early starts none), unless the last
//  read of that root, with the same root path and target path, succeeded:
//  a placed root's files[] do not change until gc. A failed read is logged
//  at Info and retried by the next load. The index (library path ->
//  root id) is built from those lists with the swap prefix pair and the
//  view's mount aliases and published in the view; library rows decorate
//  nothing, so a change of the index alone never invalidates. A remount
//  rebuilds it with the new aliases; setLibraryPrefix() rebuilds it with
//  the new pair (no I/O) and publishes the view again.
//
//  Share links (B11): LoaderSettings::shareLinks holds the share_links
//  setting. Every read of the mount table for the aliases (remount(), and
//  with links configured the start of every load and relink()) reads each
//  link with that fresh table
//  (readShareLink, on the
//  loader queue: local lstat/readlink only, never inside a network mount)
//  and builds the aliases from both (MountAliases::build(mounts, links)).
//  relink() is that read and nothing else: the same table publishes
//  nothing; a changed one rebuilds the last load's keys and publishes them
//  like a remount (PublishReason::Remount, invalidate-all only when a row
//  can decorate differently), without forcing the next load to list every
//  member folder (unless a root's own key moved, which only a root spelled
//  through a link can do), and the watch set is recomputed only when the
//  mount table itself changed. It runs at the start of every load, before
//  the CLI is asked anything, so a link the mount agent re-pointed is
//  picked up by the next load even with no event; IntakeService also calls
//  it on Refresh and 2 s and 10 s after a mount or unmount. With no links
//  configured neither runs the read: the table is read for the first load
//  and by remount() only, exactly as before B11.
//  setShareLinks() replaces the setting, then reads the links (also when
//  the list is now empty, so the old links leave the table). Each line of
//  MountAliases::notes() (a link that is ignored, or that points off the
//  share) is logged at Info once: on the first read, and whenever it is
//  new in a changed table.
//
//  Row colours (B10): setPalette() replaces LoaderSettings::palette. The
//  last successful load is rebuilt with it (IntakeSnapshot::build over the
//  same records and members, as a remount does) and published again; the
//  invalidate-all follows rendersAlike, so a colour no root uses changes
//  nothing on screen, and an inert view (no tints shown) is not
//  invalidated. The decorate path never reads the settings: it sees the
//  colours only through the visuals of the published snapshot.
//
//  Shutdown (on_quit, PLAN.md 3.2): sets the cancel flag, kills the
//  read-lane processes and closes the lane (ProcessRunner::closeReadLane),
//  so a call already on its way to the runner is never spawned. It never
//  waits for the loader queue, which may sit in a slow share call. Nothing
//  is published after it. Only read-only calls run here, so nothing else is
//  left running.
//
//  Thread-safety: every public method may be called from any thread. The
//  publish, load-finished and status-changed handlers run on the loader
//  queue.
//
//  Lifetime: queued work and pending CLI completions keep the loader's state
//  alive after the IntakeLoader object is destroyed; the destructor calls
//  shutdown().
//

#pragma once

#include <chrono>
#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "IntakeCommandArgs.h"
#include "IntakeDecorationMap.h"
#include "IntakeLibraryIndex.h"
#include "IntakeLoadPolicy.h"
#include "IntakeMountAliases.h"
#include "IntakeProcess.h"
#include "IntakeSidecarMembers.h"
#include "IntakeView.h"
#include "IntakeWatchFilter.h"
#include "IntakeWatchSet.h"

namespace intake {

enum class PublishReason {
    Load,       // a successful status load
    Inert,      // the inert state began, or its reason changed
    Remount,    // the mount aliases changed (a mount, an unmount or a share link, B11):
                // the last load's keys were rebuilt
    GatePassed, // the gate passed again after failing, then `status` failed:
                // the last load, no longer inert (state Stale)
    Reconfigured, // reconfigure(): the last load is forgotten (an empty view)
    Library,    // setLibraryPrefix(): the same view with the library index rebuilt
    Palette,    // setPalette(): the last load's visuals and badges in the new colours
};

using PublishHandler =
    std::function<void(std::shared_ptr<const IntakeView> view, bool invalidateAll, PublishReason reason)>;
using LoadFinishedHandler = std::function<void(const LoaderStatus &status)>;
// Every change of status(): a load starting (Loading), every load attempt's
// end, NotConfigured. Not called for Stopped (shutdown).
using StatusChangedHandler = std::function<void(const LoaderStatus &status)>;
using MountReader = std::function<std::vector<MountEntry>()>;
// What onWatchSet gets (see the top of this file).
struct WatchHandover {
    // The stream paths (IntakeWatchSet::streamPaths()), sorted; empty:
    // nothing to watch.
    std::vector<std::string> paths;
    // Where a new stream starts: the id taken before the latest `status`
    // call, or kWatchSinceNow (none yet, or no currentEventId).
    WatchEventId sinceEventId = kWatchSinceNow;
    // restartWatch(): replace the stream although `paths` did not change
    // (IntakeWatcher::restart); otherwise IntakeWatcher::setPaths.
    bool restart = false;
};
// Runs on the loader queue, never after shutdown().
using WatchSetHandler = std::function<void(const WatchHandover &handover)>;
// The current FSEvents event id (FSEventsGetCurrentEventId); runs on the
// loader queue.
using EventIdReader = std::function<WatchEventId()>;
// B6: runs on the loader queue with the records of every successful
// `status` load, after the mount aliases and before the snapshot is built,
// so per-root state the loader does not own (IntakeRecord::lastError, from
// IntakeRootErrors) reaches the visuals and the load diff.
// `statusStarted`: when the `status` call these records came from was
// started (IntakeRootErrors: errors set later are not judged by it).
using RecordAnnotator =
    std::function<void(std::vector<IntakeRecord> &records, std::chrono::steady_clock::time_point statusStarted)>;

struct LoaderSettings {
    // cliPath, bunPath, rulesDir and baseEnvironment (a main-thread
    // processEnvironmentSnapshot()). cliVersion and cliListsCommands are the
    // loader's to fill in.
    CliConfig cli;
    IntakePalette palette;
    ProcessLimits limits;            // read-lane budgets; the defaults are production's
    double memberLoadSeconds = 10.0; // member I/O deadline per load
    MountReader readMounts;          // empty: no mounts; runs on the loader queue
    SidecarFileAccess *files = nullptr; // null: posixSidecarFileAccess(); must outlive the loader
    PublishHandler publish;
    LoadFinishedHandler onLoadFinished; // optional: after every load attempt
    StatusChangedHandler onStatusChanged; // optional (B5: the preferences page)
    // B4 watch set. watchFolders: the watch_folders setting (absolute paths).
    std::vector<std::string> watchFolders;
    WatchSetHandler onWatchSet;         // optional
    // B11: the share_links setting (absolute, lexically clean: parseShareLinks).
    std::vector<std::string> shareLinks;
    LinkReader readLink;                // empty: posixLinkReader (local paths only); the watch set and
                                        // the share links
    EventIdReader currentEventId;       // empty: every stream starts from now (kWatchSinceNow)
    RecordAnnotator annotateRecords;    // optional (B6)
    LibraryPrefix libraryPrefix;        // B9: swap_prefix_from / swap_prefix_to
};

class IntakeLoader {
public:
    explicit IntakeLoader(LoaderSettings settings);
    ~IntakeLoader();
    IntakeLoader(const IntakeLoader &) = delete;
    IntakeLoader &operator=(const IntakeLoader &) = delete;

    // Starts a load, or queues one more after the running one.
    // `recheckVersion` runs `version` (and `income`) again even when it
    // passed before. The member pass lists every directory (no reuse).
    // `served` (optional; B5 "Reload now") runs once on the loader queue,
    // with the status then, when the load attempt that serves this request
    // ends: the next one to start (a NotConfigured attempt included), never
    // the one already running. A load discarded by reconfigure() hands it
    // on to the load that follows. Never runs after shutdown().
    void reload(bool recheckVersion, LoadFinishedHandler served = nullptr);
    // An FSEvents batch (IntakeWatcher): `directories` hold changed
    // sidecars or moved folders, as the events spelled them; `rescan`:
    // treat everything as changed. Starts or queues one load like
    // reload(false), but its member pass reuses what did not change (see
    // the top of this file).
    void reloadForChanges(std::vector<std::string> directories, bool rescan);
    // Re-reads the mount table (see the top of this file).
    void remount();
    // B11: reads the share links again with a fresh mount table and
    // publishes the keys only when the aliases changed; no CLI call, no
    // full member listing (see the top of this file). Nothing happens while
    // no link is configured.
    void relink();
    // Replaces the watch stream with the same paths, after a mount or
    // unmount; call it after reload(false) (see the top of this file).
    // Nothing happens before the first watch set was handed over.
    void restartWatch();
    // B5 (see the top of this file). From `cli`: cliPath, bunPath,
    // bunSearchDirs, rulesDir and baseEnvironment (take it with
    // processEnvironmentSnapshot() on the main thread); cliVersion and
    // cliListsCommands are reset.
    void reconfigure(CliConfig cli);
    // B5: the watch_folders setting (absolute paths, parseWatchFolders).
    void setWatchFolders(std::vector<std::string> folders);
    // B11: the share_links setting (parseShareLinks); stores it, then reads
    // the links as relink() does, even when the list is empty. No CLI call.
    void setShareLinks(std::vector<std::string> links);
    // B9: the swap prefix pair; rebuilds the library index (see the top of
    // this file). Nothing happens when it is the pair in use.
    void setLibraryPrefix(LibraryPrefix prefix);
    // B10: the row colours (the tint_* settings, IntakeTint.h). Rebuilds the
    // last load's visuals and badges with them (no CLI call, no I/O) and
    // publishes the view again, with one invalidate-all when a row or badge
    // now renders differently and the view is not inert. Later loads use
    // them. Nothing happens when it is the palette in use.
    void setPalette(IntakePalette palette);
    // See the top of this file. Idempotent.
    void shutdown();

    LoaderStatus status() const;
    std::string statusLine() const;

    struct Impl;

private:
    std::shared_ptr<Impl> impl_;
};

} // namespace intake
