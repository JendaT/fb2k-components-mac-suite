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
//      logged): IntakeStatusModel;
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
//
//  Triggers: reload() (init, a mount event, later Refresh and preferences)
//  and remount(), which re-reads the mount table and, when the aliases
//  changed, rebuilds the keys of the last load and publishes them with
//  invalidate-all. A reload requested while a load runs is coalesced into
//  one more load after it.
//
//  Shutdown (on_quit, PLAN.md 3.2): sets the cancel flag and kills the
//  read-lane processes (ProcessRunner::cancelReadLane); it never waits for
//  the loader queue, which may sit in a slow share call. Nothing is
//  published after it. Only read-only calls run here, so nothing else is
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

namespace intake {

enum class PublishReason {
    Load,    // a successful status load
    Inert,   // the inert state began, or its reason changed
    Remount, // the mount aliases changed: the last load's keys were rebuilt
};

using PublishHandler =
    std::function<void(std::shared_ptr<const IntakeView> view, bool invalidateAll, PublishReason reason)>;
using LoadFinishedHandler = std::function<void(const LoaderStatus &status)>;
using MountReader = std::function<std::vector<MountEntry>()>;

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
};

class IntakeLoader {
public:
    explicit IntakeLoader(LoaderSettings settings);
    ~IntakeLoader();
    IntakeLoader(const IntakeLoader &) = delete;
    IntakeLoader &operator=(const IntakeLoader &) = delete;

    // Starts a load, or queues one more after the running one.
    // `recheckVersion` runs `version` again even when it passed before.
    void reload(bool recheckVersion);
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
