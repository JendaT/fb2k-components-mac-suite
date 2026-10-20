//
//  RemoteApi.h
//  foo_jl_remote_mac
//
//  Request routing, access checks and command argument parsing for the
//  remote control HTTP API. SDK-free; the Integration layer executes the
//  decided route against foobar2000.
//
//  API (all JSON responses carry the current player state):
//    GET  /                    Web UI
//    GET  /api/state           Player state
//    POST /api/play_pause      Toggle play / pause (starts playback when stopped)
//    POST /api/play | /api/pause | /api/stop | /api/next | /api/previous
//    POST /api/volume?db=-42.5     Absolute volume in dB
//    POST /api/volume?delta=-0.5   Relative change in dB
//    POST /api/mute            Toggle mute
//    POST /api/seek?position=93.5  Seek to seconds
//
//  POST requests must carry the X-Fb2k-Remote header. Browsers only send a
//  custom header cross-origin after a CORS preflight, which this server never
//  approves, so other web pages cannot drive the player.
//

#pragma once

#include "HttpRequest.h"

#include <map>
#include <string>

namespace remote_api {

// Header every POST must carry (lower-case for Request::header lookups).
static const char* const kClientHeader = "x-fb2k-remote";

enum class Route {
    Index,
    State,
    PlayPause,
    Play,
    Pause,
    Stop,
    Next,
    Previous,
    Volume,
    Mute,
    Seek
};

struct Decision {
    int errorStatus = 0;        // Non-zero: answer with this status, do nothing
    Route route = Route::State;
};

// Access checks (client address, Host, client header) and routing.
Decision decide(const remote_http::Request& request, const std::string& clientIp);

// --- Volume ---
constexpr double kMinVolumeDb = -100.0;     // foobar2000's mute level
constexpr double kMaxVolumeDb = 0.0;

double clampVolumeDb(double db);

// Strict decimal parse: the whole string must be a finite number.
bool parseNumber(const std::string& text, double& out);

struct VolumeCommand {
    bool valid = false;
    bool relative = false;      // value is a delta in dB
    double value = 0.0;
};

// Reads ?db= or ?delta= (exactly one of them).
VolumeCommand parseVolumeCommand(const std::map<std::string, std::string>& query);

// New volume in dB for the command, clamped to the valid range.
double resolveVolume(double currentDb, const VolumeCommand& command);

// Reads ?position= (seconds, >= 0).
bool parseSeekPosition(const std::map<std::string, std::string>& query, double& seconds);

} // namespace remote_api
