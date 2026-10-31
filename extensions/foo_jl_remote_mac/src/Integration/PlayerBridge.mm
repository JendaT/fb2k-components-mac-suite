//
//  PlayerBridge.mm
//  foo_jl_remote_mac
//

#include "../fb2k_sdk.h"
#include "PlayerBridge.h"

#import <Foundation/Foundation.h>

#include <cmath>

using remote_api::Route;
using remote_http::Request;
using remote_http::Response;

namespace player_bridge {

namespace {

// Title-format scripts, compiled once on first use.
struct Scripts {
    titleformat_object::ptr title, artist, album;
};

const Scripts& scripts() {
    static Scripts s = [] {
        Scripts out;
        auto compiler = titleformat_compiler::get();
        compiler->compile_safe(out.title, "%title%");      // Falls back to the file name
        compiler->compile_safe(out.artist, "[%artist%]");
        compiler->compile_safe(out.album, "[%album%]");
        return out;
    }();
    return s;
}

NSString* formatNowPlaying(const playback_control_v3::ptr& pc, const titleformat_object::ptr& script) {
    pfc::string8 out;
    if (!pc->playback_format_title(nullptr, out, script, nullptr, playback_control::display_level_titles)) {
        return @"";
    }
    return [NSString stringWithUTF8String:out.c_str()] ?: @"";
}

// Two decimals is finer than any step the UI offers. NSDecimalNumber keeps
// the JSON exact ("-0.92", not "-0.92000000000000004").
NSNumber* rounded(double v) {
    if (!std::isfinite(v)) return @0;
    return [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.2f", v]
                                             locale:@{NSLocaleDecimalSeparator: @"."}];
}

Response json(NSDictionary* dict) {
    Response r;
    r.contentType = "application/json; charset=utf-8";
    r.headers.push_back({"Cache-Control", "no-store"});
    NSData* data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (data) r.body.assign((const char*)data.bytes, data.length);
    else r.status = 500;
    return r;
}

Response textError(int status, const char* message) {
    Response r;
    r.status = status;
    r.body = message;
    return r;
}

Response badRequest(const char* message) {
    return textError(400, message);
}

NSString* toNSString(const pfc::string8& s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

// JSON index: -1 stands for foobar2000's "none" (pfc_infinite).
NSNumber* indexOrNone(size_t index) {
    return index == pfc_infinite ? @(-1) : @(index);
}

struct ItemLocation {
    size_t playlist = pfc_infinite;
    size_t item = pfc_infinite;
};

ItemLocation playingLocation(const playlist_manager::ptr& pm) {
    ItemLocation loc;
    if (!pm->get_playing_item_location(&loc.playlist, &loc.item)) loc = ItemLocation{};
    return loc;
}

NSString* formatItem(const playlist_manager::ptr& pm, size_t playlist, size_t item,
                     const titleformat_object::ptr& script) {
    pfc::string8 out;
    pm->playlist_item_format_title(playlist, item, nullptr, out, script, nullptr,
                                   playback_control::display_level_none);
    return toNSString(out);
}

Response stateResponse() {
    auto pc = playback_control_v3::get();   // v3: custom (device) volume
    const bool playing = pc->is_playing();

    NSMutableDictionary* state = [NSMutableDictionary dictionary];
    state[@"state"] = !playing ? @"stopped" : (pc->is_paused() ? @"paused" : @"playing");
    state[@"volumeDb"] = rounded(pc->get_volume());
    state[@"muted"] = @(pc->is_muted());
    state[@"customVolume"] = @(pc->custom_volume_is_active());

    if (playing) {
        const Scripts& s = scripts();
        state[@"track"] = @{
            @"title": formatNowPlaying(pc, s.title),
            @"artist": formatNowPlaying(pc, s.artist),
            @"album": formatNowPlaying(pc, s.album),
            @"position": rounded(pc->playback_get_position()),
            @"length": rounded(pc->playback_get_length()),
            @"canSeek": @(pc->playback_can_seek()),
        };
    } else {
        state[@"track"] = [NSNull null];
    }

    const ItemLocation loc = playingLocation(playlist_manager::get());
    state[@"playing"] = loc.playlist == pfc_infinite
        ? (id)[NSNull null]
        : @{ @"playlist": @(loc.playlist), @"item": indexOrNone(loc.item) };
    return json(state);
}

Response playlistsResponse() {
    auto pm = playlist_manager::get();
    const size_t count = pm->get_playlist_count();

    NSMutableArray* lists = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; ++i) {
        pfc::string8 name;
        pm->playlist_get_name(i, name);
        [lists addObject:@{ @"name": toNSString(name), @"count": @(pm->playlist_get_item_count(i)) }];
    }

    return json(@{
        @"playlists": lists,
        @"active": indexOrNone(pm->get_active_playlist()),
        @"playing": indexOrNone(playingLocation(pm).playlist),
    });
}

Response playlistItemsResponse(const Request& request) {
    const auto q = remote_api::parseItemsQuery(remote_http::parseQuery(request.query));
    if (!q.valid) return badRequest("playlist_items needs ?playlist=<index>");

    auto pm = playlist_manager::get();
    if (q.playlist >= pm->get_playlist_count()) return textError(404, "no such playlist");

    const size_t total = pm->playlist_get_item_count(q.playlist);
    const remote_api::PageRange range = remote_api::pageRange(total, q.offset, q.limit);
    const Scripts& s = scripts();

    NSMutableArray* items = [NSMutableArray arrayWithCapacity:range.end - range.begin];
    for (size_t i = range.begin; i < range.end; ++i) {
        metadb_handle_ptr handle;
        const double length = pm->playlist_get_item_handle(handle, q.playlist, i) ? handle->get_length() : 0;
        [items addObject:@{
            @"title": formatItem(pm, q.playlist, i, s.title),
            @"artist": formatItem(pm, q.playlist, i, s.artist),
            @"album": formatItem(pm, q.playlist, i, s.album),
            @"length": rounded(length > 0 ? length : 0),
        }];
    }

    pfc::string8 name;
    pm->playlist_get_name(q.playlist, name);
    const ItemLocation loc = playingLocation(pm);

    return json(@{
        @"playlist": @(q.playlist),
        @"name": toNSString(name),
        @"total": @(total),
        @"offset": @(range.begin),
        @"items": items,
        @"playingItem": loc.playlist == q.playlist ? indexOrNone(loc.item) : @(-1),
    });
}

// Plays the item the way a double-click in the playlist would. A playlist
// that changed since the client loaded it answers 409, never a different track.
Response playItem(const Request& request) {
    const auto ref = remote_api::parseItemRef(remote_http::parseQuery(request.query));
    if (!ref.valid) return badRequest("play_item needs ?playlist=<index>&item=<index>");

    auto pm = playlist_manager::get();
    if (ref.playlist >= pm->get_playlist_count()) return textError(409, "playlists changed");
    const size_t total = pm->playlist_get_item_count(ref.playlist);
    if (ref.item >= total || (ref.hasCount && ref.count != total)) return textError(409, "playlist changed");

    pm->playlist_execute_default_action(ref.playlist, ref.item);
    return stateResponse();
}

} // namespace

Response execute(Route route, const Request& request) {
    auto pc = playback_control_v3::get();   // v3: custom (device) volume

    switch (route) {
        case Route::State:
        case Route::Index:
            break;
        case Route::PlayPause: pc->play_or_pause(); break;
        case Route::Play:      pc->play_or_unpause(); break;
        case Route::Pause:     pc->pause(true); break;
        case Route::Stop:      pc->stop(); break;
        case Route::Next:      pc->next(); break;
        case Route::Previous:  pc->previous(); break;
        case Route::Mute:      pc->volume_mute_toggle(); break;

        case Route::Playlists:     return playlistsResponse();
        case Route::PlaylistItems: return playlistItemsResponse(request);
        case Route::PlayItem:      return playItem(request);

        case Route::Volume: {
            const auto cmd = remote_api::parseVolumeCommand(remote_http::parseQuery(request.query));
            if (!cmd.valid) return badRequest("volume needs ?db= or ?delta=");
            if (pc->custom_volume_is_active()) {
                // Device-controlled volume has arbitrary units: steps only.
                if (!cmd.relative) return badRequest("this output device only supports volume steps");
                if (cmd.value > 0) pc->volume_up();
                else if (cmd.value < 0) pc->volume_down();
            } else {
                pc->set_volume((float)remote_api::resolveVolume(pc->get_volume(), cmd));
            }
            break;
        }

        case Route::Seek: {
            double seconds = 0;
            if (!remote_api::parseSeekPosition(remote_http::parseQuery(request.query), seconds)) {
                return badRequest("seek needs ?position=<seconds>");
            }
            if (pc->is_playing() && pc->playback_can_seek()) pc->playback_seek(seconds);
            break;
        }
    }

    // Commands answer with the resulting state so the UI updates without
    // waiting for its next poll.
    return stateResponse();
}

} // namespace player_bridge
