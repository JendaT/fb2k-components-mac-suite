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

Response badRequest(const char* message) {
    Response r;
    r.status = 400;
    r.body = message;
    return r;
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
    return json(state);
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
