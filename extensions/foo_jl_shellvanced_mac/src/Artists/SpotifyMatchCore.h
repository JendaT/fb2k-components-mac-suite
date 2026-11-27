//
//  SpotifyMatchCore.h
//  Pure rules for the optional Spotify photo source (no SDK, no AppKit, no networking).
//
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <string>
#include <vector>

#include "DeezerMatchCore.h"

namespace spmatch {

struct Image {
    std::string url;
    int width = 0;  // 0 = unknown
};

struct Candidate {
    std::string id, name, imageUrl;  // imageUrl already picked via pickImageUrl
};

// Largest image <= maxWidth px; else an image of unknown width; else the smallest one. "" if none.
inline std::string pickImageUrl(const std::vector<Image>& images, int maxWidth = 640) {
    const Image* best = nullptr;
    for (const Image& im : images)
        if (!im.url.empty() && im.width > 0 && im.width <= maxWidth && (!best || im.width > best->width)) best = &im;
    if (best) return best->url;
    for (const Image& im : images)
        if (!im.url.empty() && im.width == 0) return im.url;
    for (const Image& im : images)
        if (!im.url.empty() && (!best || im.width < best->width)) best = &im;
    return best ? best->url : std::string();
}

// Indices of ALL candidates whose name equals `artist` on artistKey (image-less ones included, so
// ambiguity is judged before any candidate is dropped).
inline std::vector<size_t> exactCandidates(const std::string& artist, const std::vector<Candidate>& cands) {
    std::vector<size_t> out;
    const std::string key = artistnames::artistKey(artist);
    if (key.empty()) return out;
    for (size_t i = 0; i < cands.size(); i++)
        if (artistnames::artistKey(cands[i].name) == key) out.push_back(i);
    return out;
}

// A candidate's normalized album titles: `primary` = album/single groups, `all` = every group
// (adds appears_on/compilation).
// `coArtistKeys` = artistKeys of the other artists credited on the candidate's albums (candidate itself excluded).
struct RemoteTitles {
    std::vector<std::string> primary, all;
    std::vector<std::string> coArtistKeys;
};

// Distinct keys present on both sides (empty keys ignored).
inline int sharedCoArtists(const std::vector<std::string>& userCo, const std::vector<std::string>& remoteCo) {
    std::vector<std::string> seen;
    for (const std::string& k : userCo) {
        if (k.empty() || std::find(seen.begin(), seen.end(), k) != seen.end()) continue;
        if (std::find(remoteCo.begin(), remoteCo.end(), k) != remoteCo.end()) seen.push_back(k);
    }
    return (int)seen.size();
}

// Spotify always needs title overlap (no small-discography shortcut):
//  - >= 2 distinct EXACT title equalities (no containment). A user ALBUM title may equal any Spotify
//    title; a user TRACK-only title may equal only a Spotify album/single (primary) title, so
//    appears_on/compilation names never confirm tracks.
//  - or exactly one strong (exact, >= 6 chars) user ALBUM title vs a Spotify album/single.
// Inputs are cleaned+normalized titles. Co-artist evidence (user tags vs the candidate's album credits) adds:
//  - >= 1 shared co-artist key AND >= 1 exact title equality of any kind (any group, tracks included), or
//  - >= 2 distinct shared co-artist keys.
inline bool confirmed(const std::vector<std::string>& userAlbums, const std::vector<std::string>& userAll,
                      const RemoteTitles& remote, const std::vector<std::string>& userCo = {}) {
    auto has = [](const std::vector<std::string>& v, const std::string& t) {
        return std::find(v.begin(), v.end(), t) != v.end();
    };
    std::vector<std::string> seen;
    for (const std::string& u : userAll) {
        if (u.empty() || has(seen, u)) continue;
        const bool isAlbum = has(userAlbums, u);
        if (has(isAlbum ? remote.all : remote.primary, u)) seen.push_back(u);
    }
    if (seen.size() >= 2) return true;
    const deezermatch::OverlapScore sc = deezermatch::scoreOverlap(userAlbums, remote.primary);
    if (sc.distinct == 1 && sc.strongSingle) return true;
    const int shared = sharedCoArtists(userCo, remote.coArtistKeys);
    if (shared >= 2) return true;
    if (shared >= 1)
        for (const std::string& u : userAll)
            if (!u.empty() && has(remote.all, u)) return true;
    return false;
}

// Index of the single confirmed candidate; none or several confirmed (ambiguous) -> -1.
inline int chooseConfirmed(const std::vector<std::string>& userAlbums, const std::vector<std::string>& userAll,
                           const std::vector<RemoteTitles>& remote, const std::vector<std::string>& userCo = {}) {
    int chosen = -1;
    for (size_t i = 0; i < remote.size(); i++) {
        if (!confirmed(userAlbums, userAll, remote[i], userCo)) continue;
        if (chosen >= 0) return -1;
        chosen = (int)i;
    }
    return chosen;
}

// A persisted rate-limit block is never trusted beyond a week from now (clock changes, corrupt file).
inline double clampBlockUntil(double loaded, double now) {
    if (!(loaded > 0)) return 0;
    const double cap = now + 7.0 * 24 * 3600;
    return loaded > cap ? cap : loaded;
}

// Stops Spotify for the session after this many consecutive failed requests.
struct FailureTracker {
    int consecutive = 0;
    static constexpr int kLimit = 5;
    void record(bool failed) { consecutive = failed ? consecutive + 1 : 0; }
    bool tripped() const { return consecutive >= kLimit; }
};

// Retry-After header (delta seconds). Missing/garbage -> `fallback`; clamped to [1, 7 days].
inline long parseRetryAfter(const std::string& v, long fallback = 3600) {
    long n = 0;
    size_t i = 0;
    while (i < v.size() && v[i] == ' ') i++;
    size_t start = i;
    while (i < v.size() && v[i] >= '0' && v[i] <= '9' && n < 100000000) n = n * 10 + (v[i++] - '0');
    if (i == start) n = fallback;
    if (n < 1) n = 1;
    if (n > 7 * 24 * 3600) n = 7 * 24 * 3600;
    return n;
}

inline std::string base64(const std::string& in) {
    static const char* t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    size_t i = 0;
    for (; i + 2 < in.size(); i += 3) {
        const uint32_t v = ((uint8_t)in[i] << 16) | ((uint8_t)in[i + 1] << 8) | (uint8_t)in[i + 2];
        out += t[v >> 18]; out += t[(v >> 12) & 63]; out += t[(v >> 6) & 63]; out += t[v & 63];
    }
    if (i + 1 == in.size()) {
        const uint32_t v = (uint8_t)in[i] << 16;
        out += t[v >> 18]; out += t[(v >> 12) & 63]; out += "==";
    } else if (i + 2 == in.size()) {
        const uint32_t v = ((uint8_t)in[i] << 16) | ((uint8_t)in[i + 1] << 8);
        out += t[v >> 18]; out += t[(v >> 12) & 63]; out += t[(v >> 6) & 63]; out += '=';
    }
    return out;
}

inline std::string basicAuthValue(const std::string& clientId, const std::string& secret) {
    return "Basic " + base64(clientId + ":" + secret);
}

// Source order: a Deezer real photo that is not cover-like wins; otherwise Spotify is tried
// (when available); a cover-like Deezer picture is only the fallback after that.
inline bool needsSpotify(bool deezerRealPhoto, bool deezerCoverLike, bool spotifyAvailable) {
    return spotifyAvailable && (!deezerRealPhoto || deezerCoverLike);
}

}  // namespace spmatch
