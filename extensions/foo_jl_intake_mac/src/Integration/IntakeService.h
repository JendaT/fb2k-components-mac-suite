//
//  IntakeService.h
//  foo_jl_intake
//
//  The component's controller (PLAN.md B3, 3.2): an initquit that owns the
//  loader (IntakeLoader) and wires it to the provider, the configuration
//  and the mount notifications.
//
//  on_init (main thread): installs the IntakeLog console backend, reads the
//  settings once (IntakeConfig), takes the environment snapshot
//  (processEnvironmentSnapshot, main thread only), creates the FSEvents
//  watcher (IntakeWatcher, B4) and starts the loader with the mount table
//  reader (IntakeMounts), the provider as its publish target, the
//  watch_folders setting and the watcher as its watch-set target. It
//  observes NSWorkspaceDidMount/DidUnmountNotification (each one forgets
//  the slow mac-volumes, with one invalidate-all when one was marked,
//  re-reads the mount table, reloads and restarts the watch stream), and
//  starts the first load.
//
//  Settings (B5): the preferences page writes configStore and posts
//  IntakeSettingsDidChangeNotification on the main thread. The service
//  reads every key again (config::load) and applies what changed, with no
//  restart: a new CLI path, bun path or rules folder rebuilds the CLI
//  configuration (a fresh environment snapshot, main thread) and hands it to
//  IntakeLoader::reconfigure, which reloads with `version`; new watched
//  folders go to IntakeLoader::setWatchFolders (a new watch set); a new log
//  level applies at once; a new library mapping goes to
//  IntakeLoader::setLibraryPrefix (B9: the library index is rebuilt) and to
//  the next Swap (serviceActionInfo); new row colours (B10, the tint_*
//  keys) go to IntakeLoader::setPalette (the last load rebuilt in them, at
//  most one invalidate-all); confirm_reject and confirm_gc reach the next
//  menu (serviceActionInfo: the ellipsis and the confirmation).
//  After every loader status change it posts
//  IntakeStatusDidChangeNotification on the main thread, so the page
//  refreshes its status block while visible (no polling).
//
//  Live updates (B4): a watcher batch (sidecar changes, moved folders,
//  rescans; debounced 1 s) becomes IntakeLoader::reloadForChanges: one
//  coalesced full `status --json`, the fingerprint diff, invalidate-all
//  only on change. The loader hands each watch set over with the FSEvents
//  event id taken before its latest `status` call, so a new stream replays
//  what that call missed instead of reloading once more. A mount or
//  unmount runs remount(), reload(false) and restartWatch().
//
//  Context actions (B6, IntakeActions): the loader's annotator copies the
//  per-root command errors (IntakeRootErrors) into each load's records
//  before the snapshot is built; a CLI settings change forgets them. The
//  menu reads serviceActionInfo() and a mutating call takes its
//  configuration from serviceMutationConfig(), both on the main thread.
//  When foo_jl_intake.test_actions holds steps at start, the temporary
//  test_actions aid gets a look after every successful load (it runs once,
//  after the leftover-run scan); otherwise nothing is installed.
//
//  Execute runs (B8): right after the service starts, on_init has
//  IntakeActions scan the cache folder for runs an earlier session left
//  (actionsStartRunScan): a live one is adopted, a dead one finished.
//
//  on_quit, in PLAN.md 3.2 order: removes the observers, stops the watch
//  stream and releases the watcher (no batch reaches the loader after
//  that), sets the cancel flag and kills the read lane
//  (IntakeLoader::shutdown), leaves mutating and execute processes alone
//  (IntakeActions stops handling their results: no refresh, no UI),
//  releases the loader and every service reference it holds, then removes
//  the log backend. The provider keeps working on its own state and still
//  accepts unregister_invalidate_callback.
//
//  Nothing here runs at static-init time.
//

#pragma once

#import <Foundation/Foundation.h>

#include <functional>
#include <string>

#include "../Core/IntakeLoadPolicy.h"
#include "../Core/IntakeSwapPlanner.h"

// Main thread, posted by the preferences page after it wrote a setting.
FOUNDATION_EXPORT NSNotificationName const IntakeSettingsDidChangeNotification;
// Main thread, posted by the service after the loader's status changed.
FOUNDATION_EXPORT NSNotificationName const IntakeStatusDidChangeNotification;

namespace intake {

// Main thread. Starts a load (coalesced with a running one); a no-op
// before on_init and after on_quit. For Refresh (B6) and the preferences
// page (B5). `recheckVersion` runs `version` (and `income`) again first.
// Also forgets the slow mac-volumes (one invalidate-all when one was
// marked), so Refresh brings their tints back. `finished` (optional) runs
// once on the main thread with the loader's status when the load serving
// this request has ended (IntakeLoader::reload), at once with state
// Stopped before on_init and after on_quit; never after on_quit for a
// request still waiting then.
void serviceReload(bool recheckVersion, std::function<void(const LoaderStatus &status)> finished = nullptr);

// Main thread. The post-command refresh (B6 calls it when a command the
// component started exits, PLAN.md 3.5, doc 04 "Refresh and invalidation"):
// one coalesced full `status --json` load with a full member listing (the
// command may have moved or written sidecars anywhere), then the
// fingerprint diff. A no-op before on_init and after on_quit.
void serviceRefreshAfterCommand();

// Main thread. The loader's status line; "Stopped" before on_init and
// after on_quit.
std::string serviceStatusLine();

// Main thread. The loader's status for the preferences page (B5): state,
// CLI version, roots, error and the income folders; state Stopped before
// on_init and after on_quit.
LoaderStatus serviceStatus();

// Main thread. What the context menu needs from the service (B6).
struct ServiceActionInfo {
    bool running = false;        // between on_init and on_quit
    bool cliConfigured = false;  // cli_path is set
    CliVersionInfo cli;          // the last passing `version` (LoaderStatus::cliInfo)
    bool confirmReject = true;   // confirm_reject
    bool confirmGc = true;       // confirm_gc (B9)
    LibraryPrefix libraryPrefix; // swap_prefix_from / swap_prefix_to (B9)
};
ServiceActionInfo serviceActionInfo();

// Main thread. The configuration for a mutating call (B6): the CLI, bun and
// rules settings with a fresh environment snapshot (main thread only), and
// the `cli` version and `commands` flag of the last passing `version`.
// False before on_init, after on_quit and without a CLI path.
bool serviceMutationConfig(CliConfig &out);

// Main thread. "Test CLI" (B5): one `version --json` with the current
// settings, built and run through the CLI runner on a background queue, so
// the CLI and bun path checks never block the main thread (a read-only
// call: killed at the 10 s budget, and on quit). `completion` runs once on
// the main thread, later, with whether the version gate passed and a
// one-line result (cliTestSummary). Before on_init and after on_quit it
// runs at once with "not running".
void serviceTestCli(std::function<void(bool ok, const std::string &text)> completion);

} // namespace intake
