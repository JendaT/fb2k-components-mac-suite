//
//  UpNext.h
//  Header-only foobar2000 SDK wrapper around the "Now Playing" playlist used
//  as the Up Next queue. Decisions live in UpNextCore.h.
//
//  Include after the component's SDK header (fb2k_sdk.h / foobar2000.h).
//  Objective-C++ only (uses dispatch_async with a block).
//  None of these helpers change the *active* playlist; they may change the
//  *playing* playlist.
//
#pragma once

#include "UpNextCore.h"

#include <dispatch/dispatch.h>

namespace upnext {
namespace fb {

// {D15EB83F-889D-435B-823B-B9DD65BDA326}
inline const GUID kSourceLabelProperty =
    { 0xd15eb83f, 0x889d, 0x435b, { 0x82, 0x3b, 0xb9, 0xdd, 0x65, 0xbd, 0xa3, 0x26 } };

// Set on Now Playing only for the duration of a Play Next / Add to Queue
// insert, so playlist callbacks (on_items_added, called synchronously) can tell
// user additions apart from replace/copy edits. Value: "next" or "queue".
// {6F0C2B6E-3A41-4C8E-9D57-1B2E8A4C7F90}
inline const GUID kAddKindProperty =
    { 0x6f0c2b6e, 0x3a41, 0x4c8e, { 0x9d, 0x57, 0x1b, 0x2e, 0x8a, 0x4c, 0x7f, 0x90 } };

// Finds the "Now Playing" playlist, creating it (at the end) if missing.
// Never activates it.
inline t_size findOrCreateNowPlaying() {
    auto pm = playlist_manager::get();
    return pm->find_or_create_playlist(kNowPlayingName);
}

// Label convention: store the BARE source name (playlist name, artist name,
// album title, "Now Playing"). Display code adds any "Next from: " prefix.
// Readers should still strip a leading "Next from: " for labels stored by
// older builds.
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

// Inside an on_items_added callback for Now Playing: 1 = Play Next,
// 2 = Add to Queue, 0 = not a Play Next / Add to Queue insert.
inline int pendingAddKind(t_size playlist) {
    pfc::array_t<uint8_t> bytes;
    if (!playlist_manager_v2::get()->playlist_get_property(playlist, kAddKindProperty, bytes) || bytes.get_size() == 0)
        return 0;
    return bytes[0] == 'n' ? 1 : bytes[0] == 'q' ? 2 : 0;
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

// Snapshot of the foobar playback queue.
inline pfc::list_t<t_playback_queue_item> captureQueue() {
    pfc::list_t<t_playback_queue_item> saved;
    playlist_manager::get()->queue_get_contents(saved);
    return saved;
}

// Re-adds `saved` on the next main-queue turn (after the default action's
// queue flush). Playlists can mutate in between, so each saved location is
// re-validated (same playlist slot still holds the same handle); otherwise
// the item is queued by handle. planQueueRestore (UpNextCore.h) drops the
// entry for the started (playlist, item) — foobar consumes a queued item it
// plays — and entries still present in the live queue.
inline void restoreQueueLater(const pfc::list_t<t_playback_queue_item>& saved,
                              t_size startedPlaylist = pfc_infinite,
                              t_size startedItem = pfc_infinite) {
    if (saved.get_count() == 0) return;
    pfc::list_t<t_playback_queue_item> copy = saved;
    dispatch_async(dispatch_get_main_queue(), ^{
        try {
            auto pm = playlist_manager::get();
            std::vector<SavedQueueEntry> entries;
            entries.reserve(copy.get_count());
            for (t_size i = 0; i < copy.get_count(); ++i) {
                const auto& item = copy[i];
                bool locationValid = false;
                if (item.m_playlist != pfc_infinite &&
                    item.m_playlist < pm->get_playlist_count() &&
                    item.m_item < pm->playlist_get_item_count(item.m_playlist)) {
                    metadb_handle_ptr current;
                    locationValid = pm->playlist_get_item_handle(current, item.m_playlist, item.m_item)
                        && current == item.m_handle;
                }
                entries.push_back({(size_t)item.m_playlist, (size_t)item.m_item,
                                   (uintptr_t)item.m_handle.get_ptr(), locationValid});
            }
            pfc::list_t<t_playback_queue_item> liveQueue;
            pm->queue_get_contents(liveQueue);
            std::vector<LiveQueueEntry> live;
            live.reserve(liveQueue.get_count());
            for (t_size i = 0; i < liveQueue.get_count(); ++i) {
                const auto& l = liveQueue[i];
                live.push_back({(size_t)l.m_playlist, (size_t)l.m_item, (uintptr_t)l.m_handle.get_ptr()});
            }
            for (const QueueRestoreOp& op : planQueueRestore(entries, (size_t)startedPlaylist,
                                                             (size_t)startedItem, live)) {
                const auto& item = copy[op.savedIndex];
                if (op.byLocation)
                    pm->queue_add_item_playlist(item.m_playlist, item.m_item);
                else
                    pm->queue_add_item(item.m_handle);
            }
        } catch (...) {}
    });
}

// Runs the playlist default action on (playlist, item), falling back to
// set_playing_playlist + play. Does not touch the queue itself.
inline void playItemRaw(t_size playlist, t_size item) {
    auto pm = playlist_manager::get();
    if (!pm->playlist_execute_default_action(playlist, item)) {
        pm->set_playing_playlist(playlist);
        pm->playlist_set_focus_item(playlist, item);
        playback_control::get()->start(playback_control::track_command_play);
    }
}

// Plays (playlist, item) and restores a previously captured queue afterwards
// (playlist_execute_default_action flushes the playback queue).
inline void playItemRestoringQueue(t_size playlist, t_size item,
                                   const pfc::list_t<t_playback_queue_item>& saved) {
    playItemRaw(playlist, item);
    restoreQueueLater(saved, playlist, item);
}

// Plays (playlist, item) without losing the foobar playback queue.
inline void playItemPreservingQueue(t_size playlist, t_size item) {
    playItemRestoringQueue(playlist, item, captureQueue());
}

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
            setSourceLabel(name.c_str());
        }
    }

    t_size count = pm->playlist_get_item_count(np);
    t_size at = plan.insertAt < count ? plan.insertAt : count;
    {
        auto pm2 = playlist_manager_v2::get();
        const char* kind = (action == Action::PlayNext) ? "next" : "queue";
        pfc::array_t<uint8_t> bytes;
        bytes.set_size(strlen(kind));
        memcpy(bytes.get_ptr(), kind, strlen(kind));
        pm2->playlist_set_property(np, kAddKindProperty, bytes);
        try { insertAt(np, at, items); } catch (...) { pm2->playlist_remove_property(np, kAddKindProperty); throw; }
        pm2->playlist_remove_property(np, kAddKindProperty);
    }

    if (plan.focusFirstInserted && items.get_count() > 0) {
        // Stopped: Play starts the items just added (not whatever had focus).
        pm->set_playing_playlist(np);
        pm->playlist_set_focus_item(np, at);
    }

    if (plan.useFoobarQueue) {
        for (t_size i = 0; i < items.get_count(); ++i) pm->queue_add_item_playlist(np, at + i);
    }
}

} // namespace detail

inline void playNext(metadb_handle_list_cref items) { detail::apply(Action::PlayNext, items); }
inline void addToQueue(metadb_handle_list_cref items) { detail::apply(Action::AddToQueue, items); }

// Replaces Now Playing with `items` and starts playback at startIndex.
// `sourceLabel` is the bare source name (see setSourceLabel). The foobar
// playback queue is preserved unless preserveQueue is false (it is captured
// before Now Playing is cleared; entries that pointed into the old Now
// Playing are re-queued by handle).
inline void playNow(metadb_handle_list_cref items, t_size startIndex, const char* sourceLabel,
                    bool preserveQueue = true) {
    auto pm = playlist_manager::get();
    pfc::list_t<t_playback_queue_item> savedQueue;
    if (preserveQueue) savedQueue = detail::captureQueue();
    t_size np = findOrCreateNowPlaying();
    pm->playlist_clear(np);
    detail::insertAt(np, 0, items);
    setSourceLabel(sourceLabel);
    if (items.get_count() == 0) return;
    if (startIndex >= items.get_count()) startIndex = 0;
    pm->playlist_set_focus_item(np, startIndex);
    detail::playItemRestoringQueue(np, startIndex, savedQueue);
}

// Copies a playlist into Now Playing and plays from startRow.
inline void playPlaylistIntoNowPlaying(t_size srcPlaylist, t_size startRow, bool preserveQueue = true) {
    auto pm = playlist_manager::get();
    pfc::string8 name;
    pm->playlist_get_name(srcPlaylist, name);
    metadb_handle_list all;
    pm->playlist_get_all_items(srcPlaylist, all);
    playNow(all, startRow, name.c_str(), preserveQueue);
}

// When playback is stopped and Now Playing has items, starts Now Playing at
// its focused item (first item if focus is unset) and returns true. Returns
// false when playing/paused or Now Playing is missing/empty (caller falls back).
inline bool startNowPlayingIfStopped() {
    auto pc = playback_control::get();
    if (pc->is_playing()) return false;
    auto pm = playlist_manager::get();
    t_size np = pm->find_playlist(kNowPlayingName);
    if (np == pfc_infinite) return false;
    t_size focus = pm->playlist_get_focus_item(np);
    auto start = stoppedStartIndex(pm->playlist_get_item_count(np),
                                   focus == pfc_infinite ? std::nullopt : std::optional<size_t>(focus));
    if (!start) return false;
    detail::playItemPreservingQueue(np, (t_size)*start);
    return true;
}

} // namespace fb
} // namespace upnext
