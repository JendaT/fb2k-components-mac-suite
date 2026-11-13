//
//  PlayerBridge.h
//  foo_jl_remote_mac
//
//  Executes API routes against foobar2000's playback_control and
//  playlist_manager and renders the results as JSON. Main thread only (SDK
//  playback and playlist calls require it).
//

#pragma once

#include "../Core/HttpRequest.h"
#include "../Core/RemoteApi.h"

namespace player_bridge {

// Runs the route and returns the response: playlist data for the playlist
// reads, otherwise the player state after the command, or a 4xx for bad
// arguments (409 when play_item's playlist changed under the client).
remote_http::Response execute(remote_api::Route route, const remote_http::Request& request);

} // namespace player_bridge
