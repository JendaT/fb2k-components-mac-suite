//
//  DeezerMatchCore.h
//  Pure matching rules for Deezer artist search results (no SDK, no AppKit).
//
#pragma once

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

#include "../../../../shared/ArtistNames.h"  // relative: the Xcode project has no shared/ include path

namespace deezermatch {

struct Candidate {
    std::string id, name, pictureUrl;
    long fans = 0;
    long nbAlbum = -1;  // -1 = unknown (not in the search payload)
};

// Deezer's "no photo" pictures contain "/images/artist//" (empty hash).
inline bool hasRealPicture(const std::string& url) {
    return !url.empty() && url.find("/images/artist//") == std::string::npos;
}

// Indices of candidates whose name equals `artist` on artistKey.
inline std::vector<size_t> exactCandidates(const std::string& artist,
                                           const std::vector<Candidate>& candidates) {
    std::vector<size_t> out;
    const std::string key = artistnames::artistKey(artist);
    if (key.empty()) return out;
    for (size_t i = 0; i < candidates.size(); i++)
        if (artistnames::artistKey(candidates[i].name) == key) out.push_back(i);
    return out;
}

namespace detail {
// Unicode-ish casefold (Latin-1/Ext-A/Greek/Cyrillic) that KEEPS accents, whitespace and punctuation; trimmed.
inline std::string casefoldExact(const std::string& name) {
    const std::string in = artistnames::detail::trim(name);
    std::string out;
    size_t i = 0;
    while (i < in.size()) {
        unsigned char c = (unsigned char)in[i];
        if (c < 0x80) { out.push_back((char)std::tolower(c)); i++; continue; }
        size_t len = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC0) ? 2 : 1;
        if (i + len > in.size()) len = in.size() - i;
        if (len == 2) {
            const unsigned orig = ((c & 0x1Fu) << 6) | ((unsigned char)in[i + 1] & 0x3Fu);
            const unsigned cp = artistnames::detail::foldCase(orig);
            if (cp < 0x800) {
                out.push_back((char)(0xC0 | (cp >> 6)));
                out.push_back((char)(0x80 | (cp & 0x3F)));
                i += len;
                continue;
            }
        }
        out.append(in, i, len);
        i += len;
    }
    return out;
}
}  // namespace detail

// Name tier: among `exact` (indices from exactCandidates), if exactly one candidate matches the local
// name case-insensitively with whitespace/punctuation preserved AND has a real picture, narrow to it; otherwise unchanged.
inline std::vector<size_t> narrowByExactName(const std::string& artist,
                                             const std::vector<Candidate>& candidates,
                                             const std::vector<size_t>& exact) {
    const std::string want = detail::casefoldExact(artist);
    if (want.empty()) return exact;
    std::vector<size_t> hits;
    for (size_t i : exact)
        if (detail::casefoldExact(candidates[i].name) == want) hits.push_back(i);
    // Only narrow to a candidate that has a real picture; otherwise keep the full key-equal set.
    if (hits.size() == 1 && hasRealPicture(candidates[hits[0]].pictureUrl)) return hits;
    return exact;
}

// Drops (..)/[..] groups, EP/LP/VA/remaster/deluxe/edition words, punctuation, case.
inline std::string normalizeTitle(const std::string& title) {
    std::string stripped;
    int depth = 0;
    for (char c : title) {
        if (c == '(' || c == '[') { depth++; continue; }
        if ((c == ')' || c == ']') && depth > 0) { depth--; continue; }
        if (depth == 0) stripped.push_back(c);
    }
    std::vector<std::string> tokens;
    std::string cur;
    auto flush = [&]() {
        if (cur.empty()) return;
        std::string t = artistnames::artistKey(cur);
        cur.clear();
        if (t.empty() || t == "ep" || t == "lp" || t == "va" || t == "remaster" ||
            t == "remastered" || t == "deluxe" || t == "edition") return;
        tokens.push_back(t);
    };
    for (char c : stripped) {
        if (std::isspace((unsigned char)c) || c == '-' || c == '/' || c == ':' || c == ',') flush();
        else cur.push_back(c);
    }
    flush();
    std::string out;
    for (const std::string& t : tokens) { if (!out.empty()) out += ' '; out += t; }
    return out;
}

namespace detail {

inline std::string asciiLowerKeep(const std::string& s) {  // byte-length preserving
    std::string o = s;
    for (char& c : o) if ((unsigned char)c < 0x80) c = (char)std::tolower((unsigned char)c);
    return o;
}
inline std::string trimSeps(const std::string& s) {  // whitespace and dash-like separators at both ends
    size_t b = 0, e = s.size();
    auto sep = [&](size_t i) {
        const unsigned char c = (unsigned char)s[i];
        return std::isspace(c) || c == '-' || c == ':' || c == ',' || c == ';';
    };
    while (b < e && sep(b)) b++;
    while (e > b && sep(e - 1)) e--;
    return s.substr(b, e - b);
}
inline bool isWordByte(char c) { return std::isalnum((unsigned char)c) || (unsigned char)c >= 0x80; }
// Word-bounded find of lowercase `needle` in lowercase `hay`.
inline size_t findWord(const std::string& hay, const std::string& needle, size_t from = 0) {
    if (needle.empty()) return std::string::npos;
    size_t pos = from;
    while ((pos = hay.find(needle, pos)) != std::string::npos) {
        const bool l = pos == 0 || !isWordByte(hay[pos - 1]);
        const size_t e = pos + needle.size();
        const bool r = e == hay.size() || !isWordByte(hay[e]);
        if (l && r) return pos;
        pos++;
    }
    return std::string::npos;
}
inline bool allDigits(const std::string& s, bool allowDot) {
    bool any = false;
    for (char c : s) {
        if (std::isdigit((unsigned char)c)) any = true;
        else if (!(allowDot && (c == '.' || c == ','))) return false;
    }
    return any;
}
// Bracket content that is only a number, a BPM ("191bpm", "200 Bpm") or a musical key ("Am", "F# minor", "8A").
inline bool bracketContentIsNoise(const std::string& content) {
    std::string c;
    for (char ch : asciiLowerKeep(artistnames::detail::trim(content))) if (!std::isspace((unsigned char)ch)) c.push_back(ch);
    if (c.empty()) return false;
    if (allDigits(c, true)) return true;
    if (c.size() > 3 && c.compare(c.size() - 3, 3, "bpm") == 0 && allDigits(c.substr(0, c.size() - 3), true)) return true;
    if (c.size() > 3 && c.compare(0, 3, "bpm") == 0 && allDigits(c.substr(3), true)) return true;
    if (c.size() >= 2 && c.size() <= 3 && (c.back() == 'a' || c.back() == 'b') &&
        allDigits(c.substr(0, c.size() - 1), false)) return true;  // Camelot 8A / 12b
    if (c[0] >= 'a' && c[0] <= 'g') {
        size_t i = 1;
        if (i < c.size() && (c[i] == '#' || c[i] == 'b')) i++;
        const std::string rest = c.substr(i);
        if (rest.empty() || rest == "m" || rest == "min" || rest == "maj" || rest == "minor" || rest == "major") return true;
    }
    return false;
}
inline std::string stripNoiseBrackets(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); i++) {
        const char o = s[i];
        if (o == '(' || o == '[') {
            const char c = (o == '(') ? ')' : ']';
            const size_t j = s.find(c, i + 1);
            if (j != std::string::npos && s.find(o, i + 1) > j && bracketContentIsNoise(s.substr(i + 1, j - i - 1))) {
                out.push_back(' ');
                i = j;
                continue;
            }
        }
        out.push_back(o);
    }
    return out;
}
// Removes "<artist or collab containing the artist> - " from the front.
inline std::string stripArtistPrefix(const std::string& s, const std::string& artist,
                                     const std::vector<std::string>& collabs) {
    size_t p = std::string::npos, len = 0;
    static const char* seps[] = {" - ", " \xE2\x80\x93 ", " \xE2\x80\x94 "};
    for (const char* sp : seps) {
        const size_t q = s.find(sp);
        if (q != std::string::npos && q > 0 && (p == std::string::npos || q < p)) { p = q; len = std::strlen(sp); }
    }
    if (p == std::string::npos) return s;
    const std::string prefix = artistnames::detail::trim(s.substr(0, p));
    const std::string rest = artistnames::detail::trim(s.substr(p + len));
    if (prefix.empty() || rest.empty()) return s;
    const std::string pk = artistnames::artistKey(prefix), ak = artistnames::artistKey(artist);
    if (pk.empty() || ak.empty()) return s;
    bool match = pk == ak;
    for (size_t i = 0; !match && i < collabs.size(); i++) match = artistnames::artistKey(collabs[i]) == pk;
    if (!match)
        for (const std::string& part : artistnames::splitArtists(prefix))
            if (artistnames::artistKey(part) == ak) { match = true; break; }
    if (!match) match = findWord(asciiLowerKeep(prefix), asciiLowerKeep(artistnames::detail::trim(artist))) != std::string::npos;
    return match ? rest : s;
}
inline std::string stripVariousPrefix(const std::string& s) {
    const std::string l = asciiLowerKeep(s);
    size_t n = 0;
    if (l.compare(0, 3, "v/a") == 0) n = 3;
    else if (s.compare(0, 2, "VA") == 0) n = 2;
    else if (l.compare(0, 15, "various artists") == 0) n = 15;
    if (n == 0 || (n < s.size() && isWordByte(s[n]))) return s;
    const std::string rest = trimSeps(s.substr(n));
    return rest.empty() ? s : rest;
}
// Cuts the earliest release-promo phrase (and everything after it), then trailing "Master16" / "Original Mix".
inline std::string stripTrailingNoise(std::string s) {
    static const char* phrases[] = {"released on", "soon on", "soon out", "out now", "free download", "compiled by"};
    const std::string l = asciiLowerKeep(s);
    size_t cut = std::string::npos;
    for (const char* ph : phrases) {
        const size_t q = findWord(l, ph);
        if (q != std::string::npos && q > 0 && !trimSeps(s.substr(0, q)).empty() && q < cut) cut = q;
    }
    if (cut != std::string::npos) s = s.substr(0, cut);
    s = trimSeps(s);
    for (bool changed = true; changed;) {
        changed = false;
        const std::string ll = asciiLowerKeep(s);
        const size_t sp = ll.find_last_of(" \t");
        if (sp == std::string::npos) break;
        const std::string last = ll.substr(sp + 1);
        bool drop = false;
        size_t dropFrom = sp;
        if (last.compare(0, 6, "master") == 0 && last.size() > 6 && allDigits(last.substr(6), false)) drop = true;
        else if (last == "mix") {
            const size_t sp2 = ll.find_last_of(" \t", sp == 0 ? 0 : sp - 1);
            if (sp2 != std::string::npos && sp2 < sp && ll.substr(sp2 + 1, sp - sp2 - 1) == "original") { drop = true; dropFrom = sp2; }
        }
        if (drop) {
            const std::string t = trimSeps(s.substr(0, dropFrom));
            if (!t.empty()) { s = t; changed = true; }
        }
    }
    return s;
}

}  // namespace detail

// Cleans a track/album title before normalizeTitle: leading "<artist / collab containing it> - ", noise
// brackets (number, BPM, key), "V/A" prefix, "Compiled By ..", "Released on ..", "Soon on/out", "Out now",
// "Free download", trailing "Master16" / "Original Mix". Never returns an empty string for a non-empty input.
inline std::string cleanTitle(const std::string& title, const std::string& artist,
                              const std::vector<std::string>& collabs = {}) {
    std::string s = artistnames::detail::trim(title);
    s = detail::stripArtistPrefix(s, artist, collabs);
    s = detail::stripVariousPrefix(s);
    s = detail::stripNoiseBrackets(s);
    s = detail::stripTrailingNoise(s);
    return s.empty() ? title : s;
}

// cleanTitle + normalizeTitle: the form compared against the other side.
inline std::string cleanNormalizedTitle(const std::string& title, const std::string& artist,
                                        const std::vector<std::string>& collabs = {}) {
    return normalizeTitle(cleanTitle(title, artist, collabs));
}

namespace detail {

// `shorter` occurs in `longer` delimited by spaces/edges (normalized titles are space-joined words).
inline bool containsWords(const std::string& longer, const std::string& shorter) {
    size_t pos = 0;
    while ((pos = longer.find(shorter, pos)) != std::string::npos) {
        const bool leftOk = pos == 0 || longer[pos - 1] == ' ';
        const size_t end = pos + shorter.size();
        const bool rightOk = end == longer.size() || longer[end] == ' ';
        if (leftOk && rightOk) return true;
        pos++;
    }
    return false;
}

enum class Match { None, Contained, Equal };

inline Match matchTitles(const std::string& a, const std::string& b) {
    if (a.empty() || b.empty()) return Match::None;
    if (a == b) return Match::Equal;
    const std::string& shorter = a.size() <= b.size() ? a : b;
    const std::string& longer = a.size() <= b.size() ? b : a;
    return (shorter.size() >= 6 && containsWords(longer, shorter)) ? Match::Contained : Match::None;
}

}  // namespace detail

// Any pair equal, or one containing the other on word boundaries with the shorter at least 6 chars.
// Inputs are expected to be normalizeTitle() results; empty strings never match.
inline bool titlesOverlap(const std::vector<std::string>& user, const std::vector<std::string>& remote) {
    for (const std::string& u : user)
        for (const std::string& r : remote)
            if (detail::matchTitles(u, r) != detail::Match::None) return true;
    return false;
}

struct OverlapScore {
    int distinct = 0;           // distinct user titles matched by some remote title
    bool strongSingle = false;  // matches include an exact equality of >= 6 chars
};

inline OverlapScore scoreOverlap(const std::vector<std::string>& user, const std::vector<std::string>& remote) {
    OverlapScore sc;
    std::vector<std::string> seen;
    for (const std::string& u : user) {
        if (u.empty() || std::find(seen.begin(), seen.end(), u) != seen.end()) continue;
        detail::Match best = detail::Match::None;
        for (const std::string& r : remote) {
            detail::Match m = detail::matchTitles(u, r);
            if (m == detail::Match::Equal) { best = m; break; }
            if (m == detail::Match::Contained) best = m;
        }
        if (best == detail::Match::None) continue;
        seen.push_back(u);
        sc.distinct++;
        if (best == detail::Match::Equal && u.size() >= 6) sc.strongSingle = true;
    }
    return sc;
}

// Picks the Deezer candidate (index into remoteTitles) whose albums confirm the user's library.
// Acceptable = at least 2 distinct overlapping titles, or exactly 1 that is an exact >= 6 char
// equality (a lone containment match is too weak). Zero or several acceptable candidates
// (ambiguous) -> -1, meaning "use the fallback".
inline int chooseCandidate(const std::vector<std::string>& user,
                           const std::vector<std::vector<std::string>>& remoteTitles) {
    int chosen = -1;
    for (size_t i = 0; i < remoteTitles.size(); i++) {
        OverlapScore sc = scoreOverlap(user, remoteTitles[i]);
        const bool ok = sc.distinct >= 2 || (sc.distinct == 1 && sc.strongSingle);
        if (!ok) continue;
        if (chosen >= 0) return -1;
        chosen = (int)i;
    }
    return chosen;
}


// Lone exact-name candidate whose albums share no title with the user's library: accept only a small
// discography (a big one is almost surely a different, more famous artist) and a distinctive name.
inline size_t keyLength(const std::string& artist) {
    size_t n = 0;
    for (unsigned char c : artistnames::artistKey(artist)) if ((c & 0xC0) != 0x80) n++;
    return n;
}
inline bool acceptLoneWithoutOverlap(const std::string& artist, long nbAlbum) {
    return nbAlbum >= 0 && nbAlbum <= 15 && keyLength(artist) >= 5;
}

// Deezer's generic grey silhouette. `rgba` is a small (~24x24) downscale, 4 bytes/pixel.
// Placeholder iff all pixels are near-grey (chroma <= 20) and >= 90% fall in the two most populated
// of 16 luma buckets (flat two-tone image).
inline bool looksLikePlaceholderPhoto(const uint8_t* rgba, int w, int h) {
    if (!rgba || w <= 0 || h <= 0) return false;
    int buckets[16] = {0};
    const int total = w * h;
    for (int i = 0; i < total; i++) {
        const int r = rgba[i * 4], g = rgba[i * 4 + 1], b = rgba[i * 4 + 2];
        const int mx = std::max(r, std::max(g, b)), mn = std::min(r, std::min(g, b));
        if (mx - mn > 20) return false;
        const int luma = (299 * r + 587 * g + 114 * b) / 1000;
        buckets[std::min(15, luma / 16)]++;
    }
    int top1 = 0, top2 = 0;
    for (int c : buckets) {
        if (c > top1) { top2 = top1; top1 = c; }
        else if (c > top2) top2 = c;
    }
    return (top1 + top2) * 10 >= total * 9;
}

}  // namespace deezermatch
