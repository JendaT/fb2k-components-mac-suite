//
//  ShellCore.h
//  foo_jl_shellvanced_mac
//
//  Pure navigation / sidebar decisions for ShellVanced. No SDK, no AppKit:
//  compiled standalone by Tests/ShellCoreTests.cpp.
//

#pragma once

#include <cmath>
#include <cstddef>
#include <cstdio>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace shellcore {

// Exact name of the hidden queue playlist (mirrors upnext::kNowPlayingName,
// kept local so this header stays SDK- and shared-free).
inline constexpr const char* kNowPlayingPlaylistName = "Now Playing";

// Values are persisted (shell_config::kLastDestKind): only ever append.
enum class DestKind { Albums, Playlist, Artist, Album };

struct Destination {
    DestKind kind = DestKind::Albums;
    std::string name;   // playlist / artist name, or album key (see albumKey); empty for Albums

    bool operator==(const Destination& o) const { return kind == o.kind && name == o.name; }
    bool operator!=(const Destination& o) const { return !(*this == o); }
};

// Browser-style back/forward history. `index_` points at the current entry
// (-1 when empty); entries after it form the forward stack.
class NavHistory {
public:
    // No-op if equal to current; otherwise truncates the forward stack.
    void push(const Destination& d) {
        if (auto cur = current(); cur && *cur == d) return;
        entries_.resize(static_cast<size_t>(index_ + 1));
        entries_.push_back(d);
        index_ = static_cast<long>(entries_.size()) - 1;
    }

    bool canGoBack() const { return index_ > 0; }
    bool canGoForward() const { return index_ >= 0 && index_ + 1 < static_cast<long>(entries_.size()); }

    std::optional<Destination> back() {
        if (!canGoBack()) return std::nullopt;
        --index_;
        return entries_[static_cast<size_t>(index_)];
    }

    std::optional<Destination> forward() {
        if (!canGoForward()) return std::nullopt;
        ++index_;
        return entries_[static_cast<size_t>(index_)];
    }

    std::optional<Destination> current() const {
        if (index_ < 0) return std::nullopt;
        return entries_[static_cast<size_t>(index_)];
    }

    // Follows a playlist rename across the whole history.
    void renamePlaylist(const std::string& oldName, const std::string& newName) {
        for (auto& e : entries_) {
            if (e.kind == DestKind::Playlist && e.name == oldName) e.name = newName;
        }
    }

    // Drops every entry matching `pred`, collapses neighbours that became
    // equal, and keeps `current` on the nearest surviving entry at or before
    // the old current (or empties the history if none survives before it).
    void removeIf(const std::function<bool(const Destination&)>& pred) {
        std::vector<Destination> out;
        long newIndex = -1;
        for (size_t i = 0; i < entries_.size(); ++i) {
            const Destination& e = entries_[i];
            bool keep = !pred(e) && (out.empty() || out.back() != e);
            if (keep) out.push_back(e);
            if (static_cast<long>(i) <= index_ && !out.empty()) {
                newIndex = static_cast<long>(out.size()) - 1;
            }
        }
        if (newIndex < 0) out.clear();   // nothing survived up to current
        entries_ = std::move(out);
        index_ = newIndex;
    }

    void remove(const Destination& d) {
        removeIf([&](const Destination& e) { return e == d; });
    }

private:
    std::vector<Destination> entries_;
    long index_ = -1;
};

// Album identity: album artist display name + U+001F + album title (the key
// AlbumViewVanced hands over). Empty artist is allowed.
inline const char* const kAlbumKeySeparator = "\x1f";

// The shell's key is artist + U+001F + title + U+001F + year (the card's year
// text, may be empty): editions of one album differ only by year. Keys saved
// before the year part existed ("artist U+001F title") still parse; year unknown.
inline std::string albumKey(const std::string& artist, const std::string& title, const std::string& year = "") {
    return artist + kAlbumKeySeparator + title + kAlbumKeySeparator + year;
}

inline std::string albumKeyArtist(const std::string& key) {
    size_t p = key.find(kAlbumKeySeparator);
    return p == std::string::npos ? std::string() : key.substr(0, p);
}

inline std::string albumKeyTitle(const std::string& key) {
    size_t p = key.find(kAlbumKeySeparator);
    if (p == std::string::npos) return key;
    size_t q = key.find(kAlbumKeySeparator, p + 1);
    return q == std::string::npos ? key.substr(p + 1) : key.substr(p + 1, q - p - 1);
}

// Empty when the key has no year part (old format) or an empty year.
inline std::string albumKeyYear(const std::string& key) {
    size_t p = key.find(kAlbumKeySeparator);
    if (p == std::string::npos) return {};
    size_t q = key.find(kAlbumKeySeparator, p + 1);
    return q == std::string::npos ? std::string() : key.substr(q + 1);
}

// "2024-02-26" -> "2024"; anything not starting with four digits is returned trimmed as is.
inline std::string albumYear(const std::string& date) {
    size_t b = 0;
    while (b < date.size() && date[b] == ' ') ++b;
    if (date.size() >= b + 4) {
        bool digits = true;
        for (size_t i = b; i < b + 4; ++i) digits = digits && date[i] >= '0' && date[i] <= '9';
        if (digits) return date.substr(b, 4);
    }
    size_t e = date.size();
    while (e > b && date[e - 1] == ' ') --e;
    return date.substr(b, e - b);
}

// "3:07" / "1:02:03"; negative or non-finite -> "".
inline std::string formatTrackLength(double seconds) {
    if (!std::isfinite(seconds) || seconds < 0) return "";
    long total = static_cast<long>(std::llround(seconds));
    char buf[32];
    if (total >= 3600) std::snprintf(buf, sizeof buf, "%ld:%02ld:%02ld", total / 3600, (total / 60) % 60, total % 60);
    else std::snprintf(buf, sizeof buf, "%ld:%02ld", total / 60, total % 60);
    return buf;
}

// "12 songs, 45 min" / "1 song, 1 hr 5 min" (minutes rounded, at least 1).
inline std::string albumStats(size_t songs, double seconds) {
    char buf[64];
    long mins = std::isfinite(seconds) && seconds > 0 ? static_cast<long>(std::llround(seconds / 60.0)) : 0;
    if (mins < 1) mins = 1;
    const char* noun = songs == 1 ? "song" : "songs";
    if (mins >= 60) {
        long h = mins / 60, m = mins % 60;
        if (m == 0) std::snprintf(buf, sizeof buf, "%zu %s, %ld hr", songs, noun, h);
        else std::snprintf(buf, sizeof buf, "%zu %s, %ld hr %ld min", songs, noun, h, m);
    } else {
        std::snprintf(buf, sizeof buf, "%zu %s, %ld min", songs, noun, mins);
    }
    return buf;
}

// Sidebar "Search in Your Library": both strings already case/accent folded.
// An empty needle matches everything.
inline bool searchMatches(const std::string& foldedHaystack, const std::string& foldedNeedle) {
    return foldedNeedle.empty() || foldedHaystack.find(foldedNeedle) != std::string::npos;
}

// Indices of playlists the sidebar shows: all but the exact "Now Playing".
inline std::vector<size_t> sidebarPlaylists(const std::vector<std::string>& names) {
    std::vector<size_t> out;
    out.reserve(names.size());
    for (size_t i = 0; i < names.size(); ++i) {
        if (names[i] != kNowPlayingPlaylistName) out.push_back(i);
    }
    return out;
}

// "Your Library" filter chips. Exclusive; none selected (All) shows both.
enum class LibraryFilter : int { All = 0, Playlists = 1, Artists = 2 };

inline LibraryFilter toggleFilter(LibraryFilter current, LibraryFilter tapped) {
    return current == tapped ? LibraryFilter::All : tapped;
}

inline bool showsPlaylists(LibraryFilter f) { return f != LibraryFilter::Artists; }
inline bool showsArtists(LibraryFilter f) { return f != LibraryFilter::Playlists; }

inline LibraryFilter filterFromInt(long long v) {
    switch (v) {
        case 1: return LibraryFilter::Playlists;
        case 2: return LibraryFilter::Artists;
        default: return LibraryFilter::All;
    }
}

} // namespace shellcore
