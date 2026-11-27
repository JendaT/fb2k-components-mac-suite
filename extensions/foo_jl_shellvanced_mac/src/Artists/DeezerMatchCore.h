//
//  DeezerMatchCore.h
//  Pure matching rules for Deezer artist search results (no SDK, no AppKit).
//
#pragma once

#include <algorithm>
#include <cctype>
#include <string>
#include <vector>

#include "../../../../shared/ArtistNames.h"  // relative: the Xcode project has no shared/ include path

namespace deezermatch {

struct Candidate {
    std::string id, name, pictureUrl;
    long fans = 0;
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

}  // namespace deezermatch
