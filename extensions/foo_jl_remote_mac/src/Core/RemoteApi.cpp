//
//  RemoteApi.cpp
//  foo_jl_remote_mac
//

#include "RemoteApi.h"
#include "NetworkPolicy.h"

#include <cerrno>
#include <cmath>
#include <cstdlib>

namespace remote_api {

namespace {

struct RouteEntry {
    const char* path;
    const char* method;
    Route route;
};

const RouteEntry kRoutes[] = {
    { "/",                "GET",  Route::Index },
    { "/index.html",      "GET",  Route::Index },
    { "/api/state",       "GET",  Route::State },
    { "/api/play_pause",  "POST", Route::PlayPause },
    { "/api/play",        "POST", Route::Play },
    { "/api/pause",       "POST", Route::Pause },
    { "/api/stop",        "POST", Route::Stop },
    { "/api/next",        "POST", Route::Next },
    { "/api/previous",    "POST", Route::Previous },
    { "/api/volume",      "POST", Route::Volume },
    { "/api/mute",        "POST", Route::Mute },
    { "/api/seek",        "POST", Route::Seek },
    { "/api/playlists",      "GET",  Route::Playlists },
    { "/api/playlist_items", "GET",  Route::PlaylistItems },
    { "/api/play_item",      "POST", Route::PlayItem },
};

Decision fail(int status) {
    Decision d;
    d.errorStatus = status;
    return d;
}

} // namespace

Decision decide(const remote_http::Request& request, const std::string& clientIp) {
    if (!remote_policy::isLocalNetworkAddress(clientIp)) return fail(403);
    if (!remote_policy::isAllowedHost(request.header("host"))) return fail(403);

    bool pathKnown = false;
    for (const RouteEntry& entry : kRoutes) {
        if (request.path != entry.path) continue;
        pathKnown = true;
        if (request.method != entry.method) continue;

        if (request.method == "POST" && request.header(kClientHeader).empty()) return fail(403);
        Decision d;
        d.route = entry.route;
        return d;
    }
    return fail(pathKnown ? 405 : 404);
}

double clampVolumeDb(double db) {
    if (std::isnan(db)) return kMinVolumeDb;
    if (db < kMinVolumeDb) return kMinVolumeDb;
    if (db > kMaxVolumeDb) return kMaxVolumeDb;
    return db;
}

bool parseNumber(const std::string& text, double& out) {
    if (text.empty() || text.size() > 32) return false;
    // strtod also takes hex, "inf", "nan" and leading spaces; plain decimals only.
    for (char c : text) {
        if (!((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+')) return false;
    }
    errno = 0;
    char* end = nullptr;
    const double v = std::strtod(text.c_str(), &end);
    if (end != text.c_str() + text.size() || errno == ERANGE || !std::isfinite(v)) return false;
    out = v;
    return true;
}

VolumeCommand parseVolumeCommand(const std::map<std::string, std::string>& query) {
    VolumeCommand cmd;
    const auto db = query.find("db");
    const auto delta = query.find("delta");
    if ((db == query.end()) == (delta == query.end())) return cmd;   // Need exactly one

    const bool relative = delta != query.end();
    double value = 0.0;
    if (!parseNumber(relative ? delta->second : db->second, value)) return cmd;

    cmd.valid = true;
    cmd.relative = relative;
    cmd.value = value;
    return cmd;
}

double resolveVolume(double currentDb, const VolumeCommand& command) {
    if (!command.valid) return clampVolumeDb(currentDb);
    return clampVolumeDb(command.relative ? currentDb + command.value : command.value);
}

bool parseSeekPosition(const std::map<std::string, std::string>& query, double& seconds) {
    const auto it = query.find("position");
    if (it == query.end()) return false;
    double v = 0.0;
    if (!parseNumber(it->second, v) || v < 0.0) return false;
    seconds = v;
    return true;
}

bool parseIndex(const std::string& text, size_t& out) {
    if (text.empty() || text.size() > 9) return false;
    size_t v = 0;
    for (char c : text) {
        if (c < '0' || c > '9') return false;
        v = v * 10 + (size_t)(c - '0');
    }
    out = v;
    return true;
}

ItemsQuery parseItemsQuery(const std::map<std::string, std::string>& query) {
    ItemsQuery q;
    const auto playlist = query.find("playlist");
    if (playlist == query.end() || !parseIndex(playlist->second, q.playlist)) return q;

    const auto offset = query.find("offset");
    if (offset != query.end() && !parseIndex(offset->second, q.offset)) return q;

    const auto limit = query.find("limit");
    if (limit != query.end()) {
        if (!parseIndex(limit->second, q.limit)) return q;
        if (q.limit < 1) q.limit = 1;
        if (q.limit > kMaxPageSize) q.limit = kMaxPageSize;
    }

    q.valid = true;
    return q;
}

ItemRef parseItemRef(const std::map<std::string, std::string>& query) {
    ItemRef ref;
    const auto playlist = query.find("playlist");
    const auto item = query.find("item");
    if (playlist == query.end() || item == query.end()) return ref;
    if (!parseIndex(playlist->second, ref.playlist) || !parseIndex(item->second, ref.item)) return ref;

    const auto count = query.find("count");
    if (count != query.end()) {
        if (!parseIndex(count->second, ref.count)) return ref;
        ref.hasCount = true;
    }

    ref.valid = true;
    return ref;
}

PageRange pageRange(size_t total, size_t offset, size_t limit) {
    PageRange r;
    r.begin = offset < total ? offset : total;
    r.end = (total - r.begin) < limit ? total : r.begin + limit;
    return r;
}

} // namespace remote_api
