//
//  IntakeStatusProvider.h
//  foo_jl_intake
//
//  The entry point IntakeService uses to start the status provider
//  (IntakeStatusProvider.mm, B14): the suite's jl_status_provider that tells
//  a host such as SimPlaylist what intake is doing (shared/jl_status_api.h).
//  The provider reads the session's activity model (IntakeActivityHub) and
//  is its one change handler; the hooks in IntakeActions and IntakeSwap
//  reach it only through the hub. Its state lives in one leaked heap
//  object, so it needs no SDK work at static-init time and still answers,
//  and accepts the host's unregister, after on_quit.
//

#pragma once

namespace intake {

// Main thread (on_init, before anything can begin an activity): the
// provider becomes the hub's change handler and takes the line it shows
// now. The host's first call does the same when it comes first; later
// calls do nothing.
void statusProviderStart();

} // namespace intake
