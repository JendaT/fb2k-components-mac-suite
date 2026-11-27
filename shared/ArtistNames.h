//
//  ArtistNames.h
//  Pure artist-name helpers: splitting collaboration strings, "Various
//  Artists" detection and a folded comparison key. Header-only, no SDK.
//
#pragma once

#include <cctype>
#include <string>
#include <string_view>
#include <vector>

namespace artistnames {

namespace detail {

inline std::string lowerAscii(std::string_view v) {
    std::string r(v);
    for (auto& c : r) c = (char)std::tolower((unsigned char)c);
    return r;
}

inline std::string trim(const std::string& v) {
    size_t b = 0, e = v.size();
    while (b < e && std::isspace((unsigned char)v[b])) b++;
    while (e > b && std::isspace((unsigned char)v[e - 1])) e--;
    return v.substr(b, e - b);
}

inline bool isJoinerWord(const std::string& w) {
    std::string l = lowerAscii(w);
    return l == "vs" || l == "vs." || l == "feat." || l == "ft." || l == "x" || l == "&";
}

// Lowercase ASCII fold for U+00C0..U+00FF.
inline const char* latin1Fold(unsigned cp) {
    static const char* t[64] = {
        "a","a","a","a","a","a","ae","c","e","e","e","e","i","i","i","i",
        "d","n","o","o","o","o","o","","o","u","u","u","u","y","th","ss",
        "a","a","a","a","a","a","ae","c","e","e","e","e","i","i","i","i",
        "d","n","o","o","o","o","o","","o","u","u","u","u","y","th","y"};
    return t[cp - 0xC0];
}

// Lowercase ASCII fold for U+0100..U+017F (run-length table).
inline const char* latinExtAFold(unsigned cp) {
    struct Run { const char* s; int n; };
    static const Run runs[] = {
        {"a",6},{"c",8},{"d",4},{"e",10},{"g",8},{"h",4},{"i",10},{"ij",2},{"j",2},
        {"k",3},{"l",10},{"n",6},{"n",1},{"n",2},{"o",6},{"oe",2},{"r",6},{"s",8},
        {"t",6},{"u",12},{"w",2},{"y",3},{"z",6},{"s",1}};
    unsigned idx = cp - 0x100;
    for (const Run& r : runs) {
        if (idx < (unsigned)r.n) return r.s;
        idx -= (unsigned)r.n;
    }
    return "";
}

} // namespace detail

// "A & B", "A vs B", "A feat. B", "A x B", "A, B", "A (B)" -> {"A","B"}.
// Joiners must be whole words with a word on each side; "AT&T", "Malcolm X"
// are left alone. Only a trailing "(...)" group becomes an extra part.
// A "Friends" pseudo-artist is dropped.
inline std::vector<std::string> splitArtists(std::string_view name) {
    std::vector<std::string> out;
    auto add = [&](std::string t) {
        t = detail::trim(t);
        if (t.empty() || detail::lowerAscii(t) == "friends") return;
        out.push_back(t);
    };

    std::string s = detail::trim(std::string(name));
    std::string extra;
    if (s.size() > 3 && s.back() == ')') {
        size_t open = s.rfind(" (");
        if (open != std::string::npos && open > 0) {
            extra = s.substr(open + 2, s.size() - open - 3);
            s = detail::trim(s.substr(0, open));
        }
    }

    std::vector<std::string> words;
    {
        std::string w;
        for (char c : s) {
            if (std::isspace((unsigned char)c)) {
                if (!w.empty()) words.push_back(w);
                w.clear();
            } else w.push_back(c);
        }
        if (!w.empty()) words.push_back(w);
    }

    std::string cur;
    auto append = [&](const std::string& w) { if (!cur.empty()) cur += ' '; cur += w; };
    for (size_t i = 0; i < words.size(); i++) {
        const std::string& w = words[i];
        const bool hasNext = i + 1 < words.size();
        if (i > 0 && hasNext && detail::isJoinerWord(w)) {
            add(cur); cur.clear();
        } else if (hasNext && w.size() > 1 && w.back() == ',') {
            append(w.substr(0, w.size() - 1));
            add(cur); cur.clear();
        } else {
            append(w);
        }
    }
    add(cur);
    if (!extra.empty()) add(extra);
    return out;
}

inline bool isVariousArtists(std::string_view name) {
    std::string l = detail::lowerAscii(detail::trim(std::string(name)));
    return l == "various artists" || l == "va" || l == "v/a";
}

// Case-, accent- and punctuation-insensitive comparison key.
inline std::string artistKey(std::string_view name) {
    std::string out;
    size_t i = 0;
    const size_t n = name.size();
    while (i < n) {
        unsigned char c = (unsigned char)name[i];
        if (c < 0x80) {
            if (std::isalnum(c)) out.push_back((char)std::tolower(c));
            i++;
            continue;
        }
        size_t len = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC0) ? 2 : 1;
        if (i + len > n) len = n - i;
        if (len == 3 && c == 0xE2 && (unsigned char)name[i + 1] == 0x80) {
            unsigned char b3 = (unsigned char)name[i + 2];
            if (b3 >= 0x90 && b3 <= 0xA7) { i += len; continue; } // U+2010-2027 punctuation
        }
        if (len == 2) {
            if (c == 0xCC || (c == 0xCD && (unsigned char)name[i + 1] <= 0xAF)) { i += len; continue; } // U+0300-036F
            unsigned cp = ((c & 0x1Fu) << 6) | ((unsigned char)name[i + 1] & 0x3Fu);
            if (cp >= 0xC0 && cp <= 0xFF) { out += detail::latin1Fold(cp); i += len; continue; }
            if (cp >= 0x100 && cp <= 0x17F) { out += detail::latinExtAFold(cp); i += len; continue; }
        }
        out.append(name.substr(i, len));  // unknown scripts kept verbatim
        i += len;
    }
    return out;
}

} // namespace artistnames
