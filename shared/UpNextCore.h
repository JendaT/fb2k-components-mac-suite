//
//  UpNextCore.h
//  Pure (SDK-free) decision logic for the "Up Next" / Now Playing playlist.
//  Header-only; unit tested by shared/Tests/UpNextCoreTests.cpp.
//
#pragma once

#include <algorithm>
#include <cctype>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace upnext {

inline constexpr const char* kNowPlayingName = "Now Playing";

enum class Action { PlayNext, AddToQueue };

struct PlaybackState {
    bool playing = false;               // playing or paused
    bool playingFromNowPlaying = false;
    size_t playingIndex = 0;            // index in the playing playlist (valid if playing)
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
};

inline EditPlan planEdit(Action action, const PlaybackState& s) {
    EditPlan p;
    const bool next = (action == Action::PlayNext);

    if (!s.playing) {
        p.insertAt = next ? (s.nowPlayingFocus ? *s.nowPlayingFocus + 1 : 0)
                          : s.nowPlayingCount;
        p.insertAt = std::min(p.insertAt, s.nowPlayingCount);
        return p;
    }

    if (s.playingFromNowPlaying) {
        if (next) {
            p.insertAt = std::min(s.playingIndex + 1, s.nowPlayingCount);
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

struct UpNextSections { bool showCurrent; size_t nextFrom; size_t nextCount; };

inline UpNextSections buildSections(bool playing, size_t playingIndex, size_t playlistCount) {
    if (!playing) return {false, 0, playlistCount};
    const size_t from = playingIndex + 1;
    return {true, from, playlistCount > from ? playlistCount - from : 0};
}

// Items foobar2000 already adds to its own context menu that our Up Next
// entries replace.
inline bool isDuplicateFoobarMenuItem(std::string_view name) {
    std::string l = detail::lower(detail::trim(name));
    return l == "play" || l == "add to playback queue";
}

} // namespace upnext
