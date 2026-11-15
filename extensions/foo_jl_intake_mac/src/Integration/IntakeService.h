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
//  (processEnvironmentSnapshot, main thread only), starts the loader with
//  the mount table reader (IntakeMounts) and the provider as its publish
//  target, observes NSWorkspaceDidMount/DidUnmountNotification (each one
//  re-reads the mount table and reloads), and starts the first load.
//
//  on_quit, in PLAN.md 3.2 order: removes the observers (B4 stops its
//  stream here too), sets the cancel flag and kills the read lane
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
// page (B5). `recheckVersion` runs `version` again first.
void serviceReload(bool recheckVersion);

// Main thread. The loader's status line for the preferences page (B5);
// "Stopped" before on_init and after on_quit.
std::string serviceStatusLine();

} // namespace intake
