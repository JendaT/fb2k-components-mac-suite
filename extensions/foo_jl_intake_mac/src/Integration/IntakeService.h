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
//  the slow mac-volumes, re-reads the mount table, reloads and restarts the
//  watch stream), and starts the first load.
//
//  Live updates (B4): a watcher batch (sidecar changes, debounced 1 s)
//  becomes IntakeLoader::reloadForChanges: one coalesced full `status
//  --json`, the fingerprint diff, invalidate-all only on change.
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

#include <string>

namespace intake {

// Main thread. Starts a load (coalesced with a running one); a no-op
// before on_init and after on_quit. For Refresh (B6) and the preferences
// page (B5). `recheckVersion` runs `version` (and `income`) again first.
void serviceReload(bool recheckVersion);

// Main thread. The post-command refresh (B6 calls it when a command the
// component started exits, PLAN.md 3.5, doc 04 "Refresh and invalidation"):
// one coalesced full `status --json` load with a full member listing (the
// command may have moved or written sidecars anywhere), then the
// fingerprint diff. A no-op before on_init and after on_quit.
void serviceRefreshAfterCommand();

// Main thread. The loader's status line for the preferences page (B5);
// "Stopped" before on_init and after on_quit.
std::string serviceStatusLine();

} // namespace intake
