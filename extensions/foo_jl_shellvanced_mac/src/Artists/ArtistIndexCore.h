//
//  ArtistIndexCore.h
//  Pure artist index builder (no SDK, no AppKit). Groups library tracks by
//  artist: album artists (collaborations split) own albums; track artists on
//  other albums get an "appears on" entry. Various Artists is excluded.
//
#pragma once

#include <algorithm>
#include <cctype>
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

// Co-artist evidence derived from the user's own tags, per artistKey: keys of the other artists credited on
// the same track (artist tag and album artist, VA album artists excluded) and the raw multi-artist strings.
struct CoArtistInfo {
    std::set<std::string> keys;
    std::set<std::string> collabStrings;
};

// Labels/compilers are not collaborators: stoplisted names or album artists spread over many track artists.
inline bool isLabelLikeName(const std::string& name) {
    std::string l;
    for (char c : name) l.push_back((unsigned char)c < 0x80 ? (char)std::tolower((unsigned char)c) : c);
    std::vector<std::string> words;
    std::string w;
    for (char c : l) {
        if (std::isalnum((unsigned char)c) || (unsigned char)c >= 0x80) w.push_back(c);
        else { if (!w.empty()) words.push_back(w); w.clear(); }
    }
    if (!w.empty()) words.push_back(w);
    for (const std::string& x : words)
        if (x == "records" || x == "recordings" || x == "music" || x == "label" || x == "sounds") return true;
    const std::string k = artistnames::artistKey(name);
    return k == "unknown" || k == "unknownartist" || k == "traditional" || k == "anonymous" || k == "various";
}

inline std::map<std::string, CoArtistInfo> buildCoArtists(const std::vector<TrackRow>& rows) {
    // Pass 1: distinct track artists per album artist.
    std::map<std::string, std::set<std::string>> spread;
    for (const TrackRow& r : rows) {
        if (r.albumArtist.empty() || artistnames::isVariousArtists(r.albumArtist)) continue;
        for (const std::string& a : artistnames::splitArtists(r.albumArtist)) {
            const std::string ak = artistnames::artistKey(a);
            if (ak.empty() || artistnames::isVariousArtists(r.artist)) continue;
            for (const std::string& t : artistnames::splitArtists(r.artist)) {
                const std::string tk = artistnames::artistKey(t);
                if (!tk.empty()) spread[ak].insert(tk);
            }
        }
    }
    std::map<std::string, CoArtistInfo> out;
    for (const TrackRow& r : rows) {
        std::set<std::string> all;
        std::vector<std::string> raws;
        if (!artistnames::isVariousArtists(r.artist) && !r.artist.empty()) {
            const std::vector<std::string> parts = artistnames::splitArtists(r.artist);
            for (const std::string& n : parts) {
                const std::string k = artistnames::artistKey(n);
                if (!k.empty()) all.insert(k);
            }
            if (parts.size() > 1) raws.push_back(r.artist);
        }
        if (!r.albumArtist.empty() && !artistnames::isVariousArtists(r.albumArtist)) {
            bool any = false;
            for (const std::string& n : artistnames::splitArtists(r.albumArtist)) {
                const std::string k = artistnames::artistKey(n);
                if (k.empty() || isLabelLikeName(n) || spread[k].size() >= 4) continue;
                all.insert(k);
                any = true;
            }
            if (any && artistnames::splitArtists(r.albumArtist).size() > 1) raws.push_back(r.albumArtist);
        }
        if (all.size() < 2) continue;
        for (const std::string& k : all) {
            CoArtistInfo& info = out[k];
            for (const std::string& o : all) if (o != k) info.keys.insert(o);
            for (const std::string& s : raws) info.collabStrings.insert(s);
        }
    }
    return out;
}

// Which tracks to probe for cover art, in order: newest date first, one track per distinct album (an empty
// album tag counts each track as its own album), then further tracks of the same albums; at most `maxProbes`.
struct CoverProbeRow {
    std::string album, date;
    size_t trackIndex;
};

inline std::vector<size_t> coverProbeOrder(const std::vector<CoverProbeRow>& rows, size_t maxProbes = 6) {
    std::vector<size_t> order(rows.size());
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return rows[a].date > rows[b].date; });
    std::vector<size_t> out, rest;
    std::set<std::string> albums;
    for (size_t i : order) {
        if (out.size() >= maxProbes) break;
        if (rows[i].album.empty() || albums.insert(rows[i].album).second) out.push_back(rows[i].trackIndex);
        else rest.push_back(rows[i].trackIndex);
    }
    for (size_t t : rest) {
        if (out.size() >= maxProbes) break;
        out.push_back(t);
    }
    return out;
}

}  // namespace artistindex
