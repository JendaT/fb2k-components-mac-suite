//
//  IntakePathProbe.h
//  foo_jl_intake
//
//  TEMPORARY (PLAN.md S0). Read-only probe: how do playlist item paths on the
//  SMB share (mac-volume://UUID/...) convert to POSIX paths, at what cost, on
//  which threads, and what do g_get_canonical_path / handle_create return for
//  a plain /Volumes/... path. Findings go to docs/intake-mac-paths.md, after
//  which this file and IntakePathProbe.mm are removed.
//
//  Runs once: at the first foobar2000 start with this build, then records
//  foo_jl_intake.s0_path_probe_done = 1 in the config store and stays quiet.
//  Logs to the console and ~/Library/Logs/foobar2000/jl_intake_path_probe.log.
//

#pragma once

#import "../fb2k_sdk.h"

namespace intake_probe {

// Called from the provider's decorate(), on the host's query queue. While the
// probe is active this session, logs path conversion for the first rows of
// the first batches (bounded); otherwise returns at once.
void onDecorateBatch(metadb_handle_list_cref items);

}  // namespace intake_probe
