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
//  level applies at once. The library mapping is only stored (B9 uses it).
//  After every loader status change it posts
//  IntakeStatusDidChangeNotification on the main thread, so the page
//  refreshes its status block while visible (no polling).
//
//  Live updates (B4): a watcher batch (sidecar changes, moved folders, a
//  stream start; debounced 1 s) becomes IntakeLoader::reloadForChanges: one
//  coalesced full `status --json`, the fingerprint diff, invalidate-all
//  only on change.
//
//  on_quit, in PLAN.md 3.2 order: removes the observers, stops the watch
//  stream and releases the watcher (no batch reaches the loader after
//  that), sets the cancel flag and kills the read lane
//  (IntakeLoader::shutdown), leaves mutating and execute processes alone
//  (none run before B6), releases the loader and every service reference it
//  holds, then removes the log backend. The provider keeps working on its
//  own state and still accepts unregister_invalidate_callback.
//
//  Nothing here runs at static-init time.
//

#pragma once

#import <Foundation/Foundation.h>

#include <functional>
#include <string>

#include "../Core/IntakeLoadPolicy.h"

// Main thread, posted by the preferences page after it wrote a setting.
FOUNDATION_EXPORT NSNotificationName const IntakeSettingsDidChangeNotification;
// Main thread, posted by the service after the loader's status changed.
FOUNDATION_EXPORT NSNotificationName const IntakeStatusDidChangeNotification;

namespace intake {

// Main thread. Starts a load (coalesced with a running one); a no-op
// before on_init and after on_quit. For Refresh (B6) and the preferences
// page (B5). `recheckVersion` runs `version` (and `income`) again first.
// Also forgets the slow mac-volumes (one invalidate-all when one was
// marked), so Refresh brings their tints back.
void serviceReload(bool recheckVersion);

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

// Main thread. "Test CLI" (B5): one `version --json` with the current
// settings, through the CLI runner on a background queue (a read-only call:
// killed at the 10 s budget, and on quit). `completion` runs once on the
// main thread with whether the version gate passed and a one-line result
// (cliTestSummary). Before on_init and after on_quit it runs at once with
// "not running".
void serviceTestCli(std::function<void(bool ok, const std::string &text)> completion);

} // namespace intake
