//
//  ArtistIndexCore.h
//  Pure artist index builder (no SDK, no AppKit). Groups library tracks by
//  artist: album artists (collaborations split) own albums; track artists on
//  other albums get an "appears on" entry. Various Artists is excluded.
//
#pragma once

#include <map>
#include <set>
#include <string>
#include <vector>

#include "../../../../shared/ArtistNames.h"  // relative: the Xcode project has no shared/ include path

namespace artistindex {

struct TrackRow {
    std::string albumArtist, artist, album, date;
    size_t trackIndex;  // caller's handle index
};

struct ArtistEntry {
    std::string name;  // display name (first spelling seen)
    std::string key;   // artistnames::artistKey(name)
    std::vector<std::string> ownedAlbums, appearsOnAlbums;
    std::vector<size_t> trackIndices;  // encounter order
    std::string newestAlbum;  // newest owned album (else newest appears-on); ties -> first seen
};

namespace detail {

struct Builder {
    ArtistEntry entry;
    std::string ownedDate, appearsDate, appearsNewest;
    bool haveOwned = false, haveAppears = false;
    std::set<std::string> ownedSet, appearsSet;
};

inline Builder& builderFor(std::map<std::string, Builder>& m, const std::string& name,
                           const std::string& key) {
    auto it = m.find(key);
    if (it == m.end()) {
        it = m.emplace(key, Builder{}).first;
        it->second.entry.name = name;
        it->second.entry.key = key;
    }
    return it->second;
}

}  // namespace detail

// Sorted by key. VA excluded. Album artist falls back to artist when empty.
inline std::vector<ArtistEntry> buildIndex(const std::vector<TrackRow>& rows) {
    std::map<std::string, detail::Builder> map;

    for (const TrackRow& r : rows) {
        const std::string& aa = r.albumArtist.empty() ? r.artist : r.albumArtist;
        const bool va = artistnames::isVariousArtists(aa);

        std::set<std::string> ownerKeys;
        if (!va) {
            for (const std::string& n : artistnames::splitArtists(aa)) {
                const std::string key = artistnames::artistKey(n);
                if (key.empty() || !ownerKeys.insert(key).second) continue;
                detail::Builder& b = detail::builderFor(map, n, key);
                b.entry.trackIndices.push_back(r.trackIndex);
                if (b.ownedSet.insert(r.album).second) {
                    b.entry.ownedAlbums.push_back(r.album);
                    if (!b.haveOwned || r.date > b.ownedDate) {
                        b.haveOwned = true;
                        b.ownedDate = r.date;
                        b.entry.newestAlbum = r.album;
                    }
                }
            }
        }

        std::set<std::string> seenTrackArtists;
        if (!artistnames::isVariousArtists(r.artist)) {
            for (const std::string& n : artistnames::splitArtists(r.artist)) {
                const std::string key = artistnames::artistKey(n);
                if (key.empty() || ownerKeys.count(key) || !seenTrackArtists.insert(key).second) continue;
                detail::Builder& b = detail::builderFor(map, n, key);
                b.entry.trackIndices.push_back(r.trackIndex);
                if (b.appearsSet.insert(r.album).second) {
                    b.entry.appearsOnAlbums.push_back(r.album);
                    if (!b.haveAppears || r.date > b.appearsDate) {
                        b.haveAppears = true;
                        b.appearsDate = r.date;
                        b.appearsNewest = r.album;
                    }
                }
            }
        }
    }

    std::vector<ArtistEntry> out;
    out.reserve(map.size());
    for (auto& kv : map) {  // std::map iterates in key order
        detail::Builder& b = kv.second;
        if (!b.haveOwned) b.entry.newestAlbum = b.appearsNewest;
        out.push_back(std::move(b.entry));
    }
    return out;
}

}  // namespace artistindex
