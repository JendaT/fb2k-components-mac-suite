//
//  IntakeNativePath.h
//  foo_jl_intake
//
//  foobar2000 item path -> a path IntakePath accepts, on the decorate path
//  (PLAN.md B3, S0 findings in docs/intake-mac-paths.md):
//   - "/..." and "file://..." are returned as given; IntakePath strips
//     file:// itself.
//   - "mac-volume://<UUID>/..." (network-share tracks) goes through
//     filesystem::g_get_native_path into `scratch`: inline, no cache. S0
//     measured about 1 us per call, no I/O, thread-safe, fine on v2's
//     decorate queue. S0 sampled resolvable UUIDs on mounted volumes only:
//     a stale UUID or one whose share is unmounted is unmeasured
//     (docs/VOLUME_UUID_ISSUE.md records timeouts for unresolvable UUIDs
//     elsewhere), so each call is timed (B4, IntakeSlowVolumeGuard): three
//     calls in a row over 20 ms mark its UUID slow, and later rows of that
//     UUID get no match without calling the SDK until resetSlowVolumes().
//     One Info line per UUID marked. While no UUID is slow or suspect the
//     guard costs two atomic loads and two clock reads per mac-volume row.
//   - Every other scheme (tidal://, soundcloud://, http://, archives, ...)
//     is no match at once, without calling into the SDK.
//
//  Thread-safety: reentrant; `scratch` is the caller's. The guard is
//  process-wide and thread-safe.
//

#pragma once

#import "../fb2k_sdk.h"

namespace intake {

class NativePathMenuBudget;

// The path to match, or nullptr for no match. The result points into `path`
// or `scratch` and is valid until either changes. `menuBudget` (the context
// menu, main thread): also skips the SDK call for a mac-volume row the
// budget refuses, and tells it how long each call took
// (IntakeSlowVolumeGuard.h: a volume is refused after 3 slow calls in the
// pass). `refused`
// (optional) is set to true when nullptr comes from a mac-volume row whose
// conversion was not tried (its volume is marked slow, or the budget
// refused it): unknown rather than no match. A conversion that was tried
// and failed (foobar2000 cannot resolve the volume) leaves it false.
const char *intakeNativePath(const char *path, pfc::string_base &scratch,
                             NativePathMenuBudget *menuBudget = nullptr, bool *refused = nullptr);

// Any thread (IntakeService calls it on the main thread for every
// NSWorkspace mount or unmount notification and on Refresh): forgets every
// slow volume. True when a volume was marked: rows the host cached empty
// for it then need an invalidate-all (the caller's job). `why` starts the
// log line ("mount change", "refresh").
bool resetSlowVolumes(const char *why);

} // namespace intake
