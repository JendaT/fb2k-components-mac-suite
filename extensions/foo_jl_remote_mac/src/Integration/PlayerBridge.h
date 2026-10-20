//
//  PlayerBridge.h
//  foo_jl_remote_mac
//
//  Executes API routes against foobar2000's playback_control and renders the
//  player state as JSON. Main thread only (SDK playback calls require it).
//

#pragma once

#include "../Core/HttpRequest.h"
#include "../Core/RemoteApi.h"

namespace player_bridge {

// Runs the route (a command, or nothing for State) and returns the response:
// the player state as JSON, or a 400 for bad command arguments.
remote_http::Response execute(remote_api::Route route, const remote_http::Request& request);

} // namespace player_bridge
