//
//  SpotifyMatchCore.h
//  Pure rules for the optional Spotify photo source (no SDK, no AppKit, no networking).
//
#pragma once

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

// Indices of candidates with a non-empty image whose name equals `artist` on artistKey.
inline std::vector<size_t> exactCandidates(const std::string& artist, const std::vector<Candidate>& cands) {
    std::vector<size_t> out;
    const std::string key = artistnames::artistKey(artist);
    if (key.empty()) return out;
    for (size_t i = 0; i < cands.size(); i++)
        if (!cands[i].imageUrl.empty() && artistnames::artistKey(cands[i].name) == key) out.push_back(i);
    return out;
}

// Lone exact candidate: title overlap with the user's library, else the small-discography rule
// (`total` = the albums endpoint's total).
inline bool acceptLone(const std::string& artist, const std::vector<std::string>& user,
                       const std::vector<std::string>& remoteTitles, long total) {
    if (deezermatch::chooseCandidate(user, {remoteTitles}) == 0) return true;
    return deezermatch::acceptLoneWithoutOverlap(artist, total);
}

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
