//
//  ShellConfig.h
//  foo_jl_shellvanced_mac
//
//  Persistent settings via fb2k::configStore (same pattern as the other
//  components' ConfigHelper.h).
//

#pragma once

#include "../fb2k_sdk.h"
#include <string>

namespace shell_config {

static const char* const kPrefix = "foo_jl_shellvanced.";

static const char* const kSidebarWidth     = "sidebar_width";      // int, points
static const char* const kSidebarCollapsed = "sidebar_collapsed";  // bool
static const char* const kLibraryFilter    = "library_filter";     // shellcore::LibraryFilter as int
static const char* const kLastDestKind     = "last_dest_kind";     // shellcore::DestKind as int
static const char* const kLastDestName     = "last_dest_name";     // string

static const int64_t kDefaultSidebarWidth = 220;
static const int64_t kMinSidebarWidth     = 180;
static const int64_t kMaxSidebarWidth     = 420;

inline std::string fullKey(const char* key) { return std::string(kPrefix) + key; }

inline int64_t getInt(const char* key, int64_t def) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) return store->getConfigInt(fullKey(key).c_str(), def);
    } catch (...) {}
    return def;
}

inline void setInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) store->setConfigInt(fullKey(key).c_str(), value);
    } catch (...) {}
}

inline bool getBool(const char* key, bool def) { return getInt(key, def ? 1 : 0) != 0; }
inline void setBool(const char* key, bool value) { setInt(key, value ? 1 : 0); }

inline std::string getString(const char* key, const char* def) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) {
            fb2k::stringRef v = store->getConfigString(fullKey(key).c_str(), def);
            if (v.is_valid()) return v->c_str();
        }
    } catch (...) {}
    return def ? def : "";
}

inline void setString(const char* key, const char* value) {
    try {
        auto store = fb2k::configStore::get();
        if (store.is_valid()) store->setConfigString(fullKey(key).c_str(), value ? value : "");
    } catch (...) {}
}

} // namespace shell_config
