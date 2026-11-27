//
//  ShellCore.h
//  foo_jl_shellvanced_mac
//
//  Pure navigation / sidebar decisions for ShellVanced. No SDK, no AppKit:
//  compiled standalone by Tests/ShellCoreTests.cpp.
//

#pragma once

#include <cstddef>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace shellcore {

// Exact name of the hidden queue playlist (mirrors upnext::kNowPlayingName,
// kept local so this header stays SDK- and shared-free).
inline constexpr const char* kNowPlayingPlaylistName = "Now Playing";

enum class DestKind { Albums, Playlist, Artist };

struct Destination {
    DestKind kind = DestKind::Albums;
    std::string name;   // playlist or artist name; empty for Albums

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
