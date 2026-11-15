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
//     decorate queue.
//   - Every other scheme (tidal://, soundcloud://, http://, archives, ...)
//     is no match at once, without calling into the SDK.
//
//  Thread-safety: reentrant; `scratch` is the caller's.
//

#pragma once

#import "../fb2k_sdk.h"

namespace intake {

// The path to match, or nullptr for no match. The result points into `path`
// or `scratch` and is valid until either changes.
const char *intakeNativePath(const char *path, pfc::string_base &scratch);

} // namespace intake
