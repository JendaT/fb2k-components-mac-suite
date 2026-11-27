//
//  ShellPlaylists.h
//  foo_jl_shellvanced_mac
//
//  Small playlist_manager helpers shared by the shell and its sidebar.
//  Playlists are tracked by name (destinations survive reordering); an index
//  hint skips the scan in the common case. Main thread only.
//

#pragma once

#include "../fb2k_sdk.h"
#include <string>
#include <vector>

inline std::vector<std::string> SVPlaylistNames() {
    std::vector<std::string> out;
    try {
        auto pm = playlist_manager::get();
        const t_size n = pm->get_playlist_count();
        out.reserve(n);
        pfc::string8 name;
        for (t_size i = 0; i < n; ++i) {
            name.reset();
            pm->playlist_get_name(i, name);
            out.emplace_back(name.c_str());
        }
    } catch (...) {}
    return out;
}

inline std::string SVPlaylistName(t_size index) {
    try {
        auto pm = playlist_manager::get();
        if (index >= pm->get_playlist_count()) return {};
        pfc::string8 name;
        pm->playlist_get_name(index, name);
        return name.c_str();
    } catch (...) {}
    return {};
}

// Exact (case-sensitive) lookup; returns pfc_infinite when missing.
inline t_size SVFindPlaylistExact(const std::string& name, t_size hint = pfc_infinite) {
    if (name.empty()) return pfc_infinite;
    if (hint != pfc_infinite && SVPlaylistName(hint) == name) return hint;
    const auto names = SVPlaylistNames();
    for (size_t i = 0; i < names.size(); ++i) {
        if (names[i] == name) return i;
    }
    return pfc_infinite;
}

inline t_size SVPlaylistItemCount(t_size index) {
    try {
        auto pm = playlist_manager::get();
        if (index < pm->get_playlist_count()) return pm->playlist_get_item_count(index);
    } catch (...) {}
    return 0;
}

inline NSString* SVToNS(const std::string& s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

inline std::string SVToStd(NSString* s) {
    return s ? std::string(s.UTF8String ?: "") : std::string();
}
