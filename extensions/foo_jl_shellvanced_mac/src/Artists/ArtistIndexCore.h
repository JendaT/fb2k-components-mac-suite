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
    std::string name;  // display name (album-artist spelling, then most frequent, then first seen)
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
    struct Spelling { std::string name; int count = 0; bool asAlbumArtist = false; };
    std::vector<Spelling> spellings;  // first-seen order

    void addSpelling(const std::string& n, bool albumArtist) {
        for (Spelling& s : spellings) {
            if (s.name == n) { s.count++; s.asAlbumArtist |= albumArtist; return; }
        }
        spellings.push_back({n, 1, albumArtist});
    }
    void pickName() {
        const Spelling* best = nullptr;
        for (const Spelling& s : spellings) {
            if (!best || (s.asAlbumArtist && !best->asAlbumArtist) ||
                (s.asAlbumArtist == best->asAlbumArtist && s.count > best->count))
                best = &s;
        }
        if (best) entry.name = best->name;
    }
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
                b.addSpelling(n, !r.albumArtist.empty());
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
                if (key.empty() || !seenTrackArtists.insert(key).second) continue;
                if (ownerKeys.count(key)) { map[key].addSpelling(n, false); continue; }
                detail::Builder& b = detail::builderFor(map, n, key);
                b.addSpelling(n, false);
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
        b.pickName();
        if (!b.haveOwned) b.entry.newestAlbum = b.appearsNewest;
        out.push_back(std::move(b.entry));
    }
    return out;
}

}  // namespace artistindex
