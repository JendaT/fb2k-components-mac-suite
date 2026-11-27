//
//  UpNextCore.h
//  Pure (SDK-free) decision logic for the "Up Next" / Now Playing playlist.
//  Header-only; unit tested by shared/Tests/UpNextCoreTests.cpp.
//
#pragma once

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace upnext {

inline constexpr const char* kNowPlayingName = "Now Playing";

enum class Action { PlayNext, AddToQueue };

struct PlaybackState {
    bool playing = false;               // playing or paused
    bool playingFromNowPlaying = false;
    size_t playingIndex = 0;            // index in the playing playlist (valid if playing && playingIndexKnown)
    bool playingIndexKnown = true;      // false: playing, but position in its playlist could not be resolved
    size_t playingPlaylist = static_cast<size_t>(-1); // playing playlist index (SDK-side bookkeeping)
    size_t playingPlaylistCount = 0;    // item count of the playing playlist
    size_t nowPlayingCount = 0;
    std::optional<size_t> nowPlayingFocus; // used when stopped
    bool shuffle = false;
};

struct EditPlan {
    bool copyRemainder = false;          // replace NP with playing playlist [copyFrom, end)
    size_t copyFrom = 0;
    bool switchPlayingToNowPlaying = false;
    bool useFoobarQueue = false;         // PlayNext under shuffle
    size_t insertAt = 0;                 // NP index after any copy
    bool focusFirstInserted = false;     // stopped: the inserted items are what Play starts next
};

inline EditPlan planEdit(Action action, const PlaybackState& s) {
    EditPlan p;
    const bool next = (action == Action::PlayNext);

    if (!s.playing) {
        p.insertAt = next ? (s.nowPlayingFocus ? *s.nowPlayingFocus + 1 : 0)
                          : s.nowPlayingCount;
        p.insertAt = std::min(p.insertAt, s.nowPlayingCount);
        p.focusFirstInserted = true;
        return p;
    }

    if (s.playingFromNowPlaying) {
        if (next) {
            // Unknown position: never follow user focus while playing; go to the front.
            p.insertAt = s.playingIndexKnown ? std::min(s.playingIndex + 1, s.nowPlayingCount) : 0;
            p.useFoobarQueue = s.shuffle;
        } else {
            p.insertAt = s.nowPlayingCount;
        }
        return p;
    }

    // Playing from some other playlist: NP becomes the remainder of it.
    p.copyRemainder = true;
    p.copyFrom = s.playingIndex;
    p.switchPlayingToNowPlaying = true;
    const size_t remainder = s.playingPlaylistCount > s.playingIndex
                                 ? s.playingPlaylistCount - s.playingIndex : 0;
    if (next) {
        p.insertAt = std::min<size_t>(1, remainder);
        p.useFoobarQueue = s.shuffle;
    } else {
        p.insertAt = remainder;
    }
    return p;
}

namespace detail {
inline std::string lower(std::string_view v) {
    std::string r(v);
    for (auto& c : r) c = (char)std::tolower((unsigned char)c);
    return r;
}
inline std::string trim(std::string_view v) {
    size_t b = 0, e = v.size();
    while (b < e && std::isspace((unsigned char)v[b])) b++;
    while (e > b && std::isspace((unsigned char)v[e - 1])) e--;
    return std::string(v.substr(b, e - b));
}
} // namespace detail

inline bool isShuffleOrderName(std::string_view name) {
    std::string l = detail::lower(name);
    return l.find("shuffle") != std::string::npos || l.find("random") != std::string::npos;
}

// Picks the playing index: the SDK's location wins, else the index found by
// handle lookup, else unknown (nullopt).
inline std::optional<size_t> resolvePlayingIndex(bool locationKnown, size_t locationIndex,
                                                 std::optional<size_t> foundIndex) {
    if (locationKnown) return locationIndex;
    return foundIndex;
}

struct UpNextSections { bool showCurrent; size_t nextFrom; size_t nextCount; };

inline UpNextSections buildSections(bool playing, size_t playingIndex, size_t playlistCount) {
    if (!playing) return {false, 0, playlistCount};
    const size_t from = playingIndex + 1;
    return {true, from, playlistCount > from ? playlistCount - from : 0};
}

// Transient bar feedback after Play Next / Add to Queue added `count` tracks.
inline std::string addedFeedbackText(size_t count, bool playNext) {
    const std::string n = std::to_string(count);
    const char* noun = count == 1 ? " track" : " tracks";
    return playNext ? "Playing " + n + noun + " next"
                    : "Added " + n + noun + " to queue";
}

// Item Play starts from when stopped: Now Playing's focus, else the first item.
// nullopt when Now Playing is empty.
inline std::optional<size_t> stoppedStartIndex(size_t nowPlayingCount, std::optional<size_t> focus) {
    if (nowPlayingCount == 0) return std::nullopt;
    if (focus && *focus < nowPlayingCount) return *focus;
    return size_t(0);
}

// ---- Queue restore after a queue-flushing play ----
inline constexpr size_t kNoIndex = static_cast<size_t>(-1);

// A playback-queue entry captured before the play. locationValid: at restore
// time (playlist, item) still holds the same handle (else re-add by handle).
struct SavedQueueEntry {
    size_t playlist = kNoIndex;
    size_t item = kNoIndex;
    uintptr_t handle = 0;
    bool locationValid = false;
};

// An entry in the live queue at restore time (playlist == kNoIndex: by handle).
struct LiveQueueEntry {
    size_t playlist = kNoIndex;
    size_t item = kNoIndex;
    uintptr_t handle = 0;
};

struct QueueRestoreOp {
    size_t savedIndex;   // index into the saved list
    bool byLocation;     // re-add as (playlist, item), else by handle
};

// Decides which saved entries to re-add, in order:
//  - the FIRST saved entry whose valid location equals the started
//    (playlist, item) is skipped (foobar consumes a queued item it plays);
//  - entries still present in the live queue are skipped (the default action
//    did not flush, or flushed later): a by-location entry matches a live
//    entry with the same playlist + item, a by-handle entry matches a live
//    entry with the same handle. Each live entry matches at most once.
inline std::vector<QueueRestoreOp> planQueueRestore(const std::vector<SavedQueueEntry>& saved,
                                                    size_t startedPlaylist, size_t startedItem,
                                                    const std::vector<LiveQueueEntry>& live) {
    std::vector<QueueRestoreOp> ops;
    std::vector<bool> liveUsed(live.size(), false);
    bool startedSkipped = false;
    for (size_t i = 0; i < saved.size(); ++i) {
        const SavedQueueEntry& e = saved[i];
        const bool byLocation = e.locationValid && e.playlist != kNoIndex;
        if (byLocation && !startedSkipped && startedPlaylist != kNoIndex &&
            e.playlist == startedPlaylist && e.item == startedItem) {
            startedSkipped = true;
            continue;
        }
        bool present = false;
        for (size_t j = 0; j < live.size(); ++j) {
            if (liveUsed[j]) continue;
            const LiveQueueEntry& l = live[j];
            const bool match = byLocation ? (l.playlist == e.playlist && l.item == e.item)
                                          : (e.handle != 0 && l.handle == e.handle);
            if (match) { liveUsed[j] = true; present = true; break; }
        }
        if (present) continue;
        if (!byLocation && e.handle == 0) continue;   // nothing to re-add
        ops.push_back({i, byLocation});
    }
    return ops;
}

// Items foobar2000 already adds to its own context menu that our Up Next
// entries replace.
inline bool isDuplicateFoobarMenuItem(std::string_view name) {
    std::string l = detail::lower(detail::trim(name));
    return l == "play" || l == "add to playback queue";
}

} // namespace upnext
