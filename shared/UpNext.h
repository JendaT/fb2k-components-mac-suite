//
//  UpNext.h
//  Header-only foobar2000 SDK wrapper around the "Now Playing" playlist used
//  as the Up Next queue. Decisions live in UpNextCore.h.
//
//  Include after the component's SDK header (fb2k_sdk.h / foobar2000.h).
//  None of these helpers change the *active* playlist; they may change the
//  *playing* playlist.
//
#pragma once

#include "UpNextCore.h"

namespace upnext {
namespace fb {

// {D15EB83F-889D-435B-823B-B9DD65BDA326}
inline const GUID kSourceLabelProperty =
    { 0xd15eb83f, 0x889d, 0x435b, { 0x82, 0x3b, 0xb9, 0xdd, 0x65, 0xbd, 0xa3, 0x26 } };

// Finds the "Now Playing" playlist, creating it (at the end) if missing.
// Never activates it.
inline t_size findOrCreateNowPlaying() {
    auto pm = playlist_manager::get();
    return pm->find_or_create_playlist(kNowPlayingName);
}

inline void setSourceLabel(const char* label) {
    t_size np = findOrCreateNowPlaying();
    pfc::string8 s(label ? label : "");
    pfc::array_t<uint8_t> bytes;
    bytes.set_size(s.length());
    if (s.length()) memcpy(bytes.get_ptr(), s.c_str(), s.length());
    playlist_manager_v2::get()->playlist_set_property(np, kSourceLabelProperty, bytes);
}

inline pfc::string8 getSourceLabel() {
    auto pm = playlist_manager::get();
    t_size np = pm->find_playlist(kNowPlayingName);
    pfc::string8 out;
    if (np != pfc_infinite) {
        pfc::array_t<uint8_t> bytes;
        if (playlist_manager_v2::get()->playlist_get_property(np, kSourceLabelProperty, bytes) && bytes.get_size() > 0) {
            out.add_string((const char*)bytes.get_ptr(), bytes.get_size());
        }
    }
    if (out.is_empty()) out = kNowPlayingName;
    return out;
}

inline PlaybackState currentPlaybackState() {
    PlaybackState s;
    auto pm = playlist_manager::get();
    auto pc = playback_control::get();

    t_size np = pm->find_playlist(kNowPlayingName);
    if (np != pfc_infinite) {
        s.nowPlayingCount = pm->playlist_get_item_count(np);
        t_size focus = pm->playlist_get_focus_item(np);
        if (focus != pfc_infinite) s.nowPlayingFocus = (size_t)focus;
    }

    if (pc->is_playing()) {
        s.playing = true;
        t_size pl = pfc_infinite, idx = pfc_infinite;
        const bool located = pm->get_playing_item_location(&pl, &idx);
        std::optional<size_t> found;
        if (!located) {
            // Location is unknown (e.g. right after set_playing_playlist):
            // look the now-playing handle up by identity.
            metadb_handle_ptr cur;
            if (pc->get_now_playing(cur) && cur.is_valid()) {
                t_size candidates[2] = { np, pm->get_playing_playlist() };
                for (t_size c : candidates) {
                    if (c == pfc_infinite) continue;
                    metadb_handle_list all;
                    pm->playlist_get_all_items(c, all);
                    for (t_size i = 0; i < all.get_count(); ++i) {
                        if (all[i] == cur) { pl = c; found = i; break; }
                    }
                    if (found) break;
                }
            }
        }
        auto resolved = resolvePlayingIndex(located, idx, found);
        if (resolved && pl != pfc_infinite) {
            s.playingIndex = *resolved;
            s.playingPlaylist = pl;
            s.playingPlaylistCount = pm->playlist_get_item_count(pl);
            s.playingFromNowPlaying = (np != pfc_infinite && pl == np);
        } else {
            // Playing something we cannot place: treat as playing from Now
            // Playing at an unknown position (Play Next goes to the front).
            s.playingIndexKnown = false;
            s.playingFromNowPlaying = true;
        }
    }

    t_size order = pm->playback_order_get_active();
    s.shuffle = isShuffleOrderName(pm->playback_order_get_name(order));
    return s;
}

namespace detail {

inline void insertAt(t_size np, t_size at, metadb_handle_list_cref items) {
    if (items.get_count() == 0) return;
    playlist_manager::get()->playlist_insert_items(np, at, items, bit_array_false());
}

inline void apply(Action action, metadb_handle_list_cref items) {
    auto pm = playlist_manager::get();
    t_size np = findOrCreateNowPlaying();
    const PlaybackState state = currentPlaybackState();
    EditPlan plan = planEdit(action, state);

    if (plan.copyRemainder) {
        t_size pl = state.playingPlaylist;
        if (pl != pfc_infinite && pl != np) {
            pfc::string8 name;
            pm->playlist_get_name(pl, name);
            metadb_handle_list all;
            pm->playlist_get_all_items(pl, all);
            metadb_handle_list rest;
            for (t_size i = plan.copyFrom; i < all.get_count(); ++i) rest.add_item(all[i]);

            pm->playlist_clear(np);
            insertAt(np, 0, rest);
            if (plan.switchPlayingToNowPlaying) pm->set_playing_playlist(np);
            pm->playlist_set_focus_item(np, 0);
            pfc::string8 label("Next from: ");
            label << name;
            setSourceLabel(label.c_str());
        }
    }

    t_size count = pm->playlist_get_item_count(np);
    t_size at = plan.insertAt < count ? plan.insertAt : count;
    insertAt(np, at, items);

    if (plan.useFoobarQueue) {
        for (t_size i = 0; i < items.get_count(); ++i) pm->queue_add_item_playlist(np, at + i);
    }
}

} // namespace detail

inline void playNext(metadb_handle_list_cref items) { detail::apply(Action::PlayNext, items); }
inline void addToQueue(metadb_handle_list_cref items) { detail::apply(Action::AddToQueue, items); }

// Replaces Now Playing with `items` and starts playback at startIndex.
inline void playNow(metadb_handle_list_cref items, t_size startIndex, const char* sourceLabel) {
    auto pm = playlist_manager::get();
    t_size np = findOrCreateNowPlaying();
    pm->playlist_clear(np);
    detail::insertAt(np, 0, items);
    setSourceLabel(sourceLabel);
    if (items.get_count() == 0) return;
    if (startIndex >= items.get_count()) startIndex = 0;
    pm->playlist_set_focus_item(np, startIndex);
    if (!pm->playlist_execute_default_action(np, startIndex)) {
        pm->set_playing_playlist(np);
        pm->playlist_set_focus_item(np, startIndex);
        playback_control::get()->start(playback_control::track_command_play);
    }
}

// Copies a playlist into Now Playing and plays from startRow.
inline void playPlaylistIntoNowPlaying(t_size srcPlaylist, t_size startRow) {
    auto pm = playlist_manager::get();
    pfc::string8 name;
    pm->playlist_get_name(srcPlaylist, name);
    metadb_handle_list all;
    pm->playlist_get_all_items(srcPlaylist, all);
    pfc::string8 label("Next from: ");
    label << name;
    playNow(all, startRow, label.c_str());
}

} // namespace fb
} // namespace upnext
