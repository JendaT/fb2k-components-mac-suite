# Installing a suite component from a dependent's preferences (jl_dependency)

`shared/jl_dependency/` lets one component of the suite install another one it
needs, from its own preferences page: what is missing, a button, a confirmation
with the real version and size, the download from the GitHub release, checks,
the install into `user-components`, and a restart that comes back to the same
page. Waveform Seekbar uses it for BPM Analyzer (phrase markers); any component
can use it the same way.

Nothing is downloaded without the user's click.

## Files

| File | What it is |
|------|-----------|
| `jl_dependency_core.h` | Pure C++ (tested): versions, picking a release, the SHA256SUMS line, allowed hosts, the archive listing check, the gate's state, the resume note |
| `jl_dependency_names.h` | Per-component Objective-C class names (see "Class prefix") |
| `JLComponentInstaller.h/.mm` | Foundation only: release lookup, download, checks, install, set-aside bundles, the install lock |
| `JLDependencyGate.h/.mm` | AppKit + SDK: `JLDependencyManager` (the flow, one per dependency) and `JLDependencyGate` (the view under the settings) |

## Using it in a component

1. **Class prefix.** Objective-C class names are global to the process, so each
   component compiles the classes under its own prefix. Add
   `src/Integration/JLDependencyPrefix.h`:

   ```objc
   #pragma once
   #define JL_DEPENDENCY_PREFIX SimPl   // unique per component
   ```

   Include it before any `jl_dependency` header.

2. **Compile the shared code** through two one-line units in
   `src/Integration/` (separate files: both `.mm` files have file-local helpers
   with the same names):

   ```objc
   // JLComponentInstallerUnit.mm
   #include "JLDependencyPrefix.h"
   #include "../../../../shared/jl_dependency/JLComponentInstaller.mm"

   // JLDependencyGateUnit.mm
   #include "../fb2k_sdk.h"
   #include "JLDependencyPrefix.h"
   #include "../../../../shared/jl_dependency/JLDependencyGate.mm"
   ```

   Run `./Scripts/build.sh --regenerate` after adding them.

3. **Describe the dependency once**, with a function returning the one manager
   (Waveform Seekbar: `src/Integration/BpmDependency.mm`):

   ```objc
   JLDependencyManager *simplaylistFooDependency(void) {
       static JLDependencyManager *manager;
       static dispatch_once_t once;
       dispatch_once(&once, ^{
           JLDependencyDescriptor *d = [[JLDependencyDescriptor alloc] init];
           d.component = @"foo_jl_foo";                    // folder, bundle and executable name
           d.displayName = @"Foo";                         // shown in the gate and the dialogs
           d.tagPrefix = @"foo-v";                         // the release tags, as release_component.sh makes them
           d.assetName = @"foo_jl_foo.fb2k-component";     // the release asset
           d.minVersion = @"1.2.0";                        // the oldest version this component works with
           d.repository = @"JendaT/fb2k-components-mac-suite";
           d.dependentName = @"SimPlaylist";               // this component: the lock and the resume note name it
           manager = [JLDependencyManager managerForDescriptor:d];
           manager.serviceAvailable = ^BOOL { /* the dependency's service resolves, e.g. std_api_try_get */ };
           manager.preferencesPageGUID = @"{...}";         // this component's page, reopened after the restart
           manager.enableFeature = ^{ /* switch on the setting that needed it */ };
       });
       return manager;
   }
   ```

   `serviceAvailable` decides "installed and loaded": check the dependency's
   API service (and its version, through a GUID that changes with the layout),
   not only the bundle on disk.

4. **The gate on the preferences page**, under the settings that need the
   dependency, only when it is needed:

   ```objc
   JLDependencyManager *dep = simplaylistFooDependency();
   if ([dep needsGate]) {
       JLDependencyGate *gate = [[JLDependencyGate alloc] initWithFrame:NSMakeRect(x, y, width, 62) manager:dep];
       [gate setFrameSize:NSMakeSize(width, gate.preferredHeight)];   // the note after an install is shorter
       [page addSubview:gate];
       y += gate.preferredHeight + gap;
   }
   ```

   Grey out the dependent settings while `needsGate` is true and the service
   is missing.

5. **At launch**, in the component's `initquit::on_init`:

   ```objc
   [simplaylistFooDependency() resumeAfterLaunch];
   ```

   It removes bundles an update set aside, and after an install acts on the
   resume note: calls `enableFeature`, reopens the page and shows "Foo 1.2.0
   installed.", or says foobar2000 did not load it.

## What the dependency's releases need

- Tags `<tagPrefix><version>` (`foo-v1.2.0`) and the asset named `assetName`:
  `./Scripts/release_component.sh` makes both.
- A `SHA256SUMS` asset listing the package. `release_component.sh` creates and
  uploads it since 787b75c on `dev/bpm`; until that is on main, releases of
  other components have none and the install refuses them.
- The bundle's `CFBundleShortVersionString` at least `minVersion`, an
  executable named after `component`, and an ad hoc code signature
  (`codesign --verify --strict` must pass).

## Trust model and checks

HTTPS to GitHub only: the API, the release's own download URLs, and redirects
to GitHub's two release storage hosts. The repository is pinned in every URL.
The package's SHA-256 must match `SHA256SUMS` (this protects the download, not
against a compromised GitHub account). The archive listing must be one bundle
(no symlinks, nothing outside it), then the unpacked tree is walked again, and
the bundle's executable, version and signature are checked before it is moved
into place with `rename(2)`. A bundle it replaces is set aside and removed at
the next launch (or put back if the install died half way). A flock lock in
`<profile>/.jl-install/` keeps two components from installing at once; the
gate shows "being installed from <dependent>" meanwhile.

## Testing notes

- Pure core tests: Waveform Seekbar's `Tests/DependencyCoreTests.cpp`; the
  release lookup against fixtures: `Tests/DependencyReleaseTests.mm`.
- Little Snitch on the development Mac blocks unsigned test binaries'
  connections to `release-assets.githubusercontent.com`, so the download can
  only be tried inside foobar2000 (allow it there once).
- To try the flow: remove the dependency in Preferences > Components, restart,
  open the dependent's page.
