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
//      `commands` into CliConfig (cliVersion, cliListsCommands);
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
//   5. IntakeSnapshot, published with invalidate-all on the first successful
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
//  with `status` (never inert).
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
//  only; the aliases still change through remount().
//
//  Incremental member lists (B4, IntakeSidecarMembers MemberReuse): a load
//  started only by reloadForChanges() lists again just the directories its
//  batches named (mapped to match keys through the watch set and the mount
//  aliases); other directories keep the previous classification. Any other
//  trigger, a remount, a rescan batch, a batch directory that maps to no
//  watched folder, or a member pass that stopped early makes the next load
//  list everything as before. Directories named by a load that failed
//  before its member pass carry over to the next load. A batch with no
//  directory and no rescan (the watcher's catch-up after a stream started)
//  runs `status` and lists only what is new.
//
//  Shutdown (on_quit, PLAN.md 3.2): sets the cancel flag, kills the
//  read-lane processes and closes the lane (ProcessRunner::closeReadLane),
//  so a call already on its way to the runner is never spawned. It never
//  waits for the loader queue, which may sit in a slow share call. Nothing
//  is published after it. Only read-only calls run here, so nothing else is
//  left running.
//
//  Thread-safety: every public method may be called from any thread. The
//  publish and load-finished handlers run on the loader queue.
//
//  Lifetime: queued work and pending CLI completions keep the loader's state
//  alive after the IntakeLoader object is destroyed; the destructor calls
//  shutdown().
//

#pragma once

#include <functional>
#include <memory>
#include <string>
#include <vector>

#include "IntakeCommandArgs.h"
#include "IntakeDecorationMap.h"
#include "IntakeLoadPolicy.h"
#include "IntakeMountAliases.h"
#include "IntakeProcess.h"
#include "IntakeSidecarMembers.h"
#include "IntakeView.h"
#include "IntakeWatchSet.h"

namespace intake {

enum class PublishReason {
    Load,       // a successful status load
    Inert,      // the inert state began, or its reason changed
    Remount,    // the mount aliases changed: the last load's keys were rebuilt
    GatePassed, // the gate passed again after failing, then `status` failed:
                // the last load, no longer inert (state Stale)
};

using PublishHandler =
    std::function<void(std::shared_ptr<const IntakeView> view, bool invalidateAll, PublishReason reason)>;
using LoadFinishedHandler = std::function<void(const LoaderStatus &status)>;
using MountReader = std::function<std::vector<MountEntry>()>;
// The stream paths (IntakeWatchSet::streamPaths()), sorted; empty: nothing
// to watch. Runs on the loader queue, never after shutdown().
using WatchSetHandler = std::function<void(const std::vector<std::string> &paths)>;

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
    // B4 watch set. watchFolders: the watch_folders setting (absolute paths).
    std::vector<std::string> watchFolders;
    WatchSetHandler onWatchSet;         // optional
    LinkReader readLink;                // empty: posixLinkReader (local paths only)
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
    void reload(bool recheckVersion);
    // An FSEvents batch (IntakeWatcher): `directories` hold changed
    // sidecars or moved folders, as the events spelled them; `rescan`:
    // treat everything as changed. Starts or queues one load like
    // reload(false), but its member pass reuses what did not change (see
    // the top of this file).
    void reloadForChanges(std::vector<std::string> directories, bool rescan);
    // Re-reads the mount table (see the top of this file).
    void remount();
    // See the top of this file. Idempotent.
    void shutdown();

    LoaderStatus status() const;
    std::string statusLine() const;

    struct Impl;

private:
    std::shared_ptr<Impl> impl_;
};

} // namespace intake
