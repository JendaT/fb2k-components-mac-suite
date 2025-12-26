//
//  ScrobbleConfig.h
//  foo_scrobble_mac
//
//  Configuration storage using fb2k::configStore
//  Note: cfg_var does NOT persist on macOS v2 - use configStore instead
//

#pragma once

#include "../fb2k_sdk.h"
#include <string>

namespace scrobble_config {

// Configuration key prefix
static const char* const kPrefix = "foo_scrobble.";

// Configuration keys
static const char* const kEnableScrobbling = "enable_scrobbling";
static const char* const kEnableNowPlaying = "enable_now_playing";
static const char* const kSubmitOnlyInLibrary = "submit_only_library";
static const char* const kSubmitDynamicSources = "submit_dynamic";

// Titleformat mappings (advanced)
static const char* const kArtistFormat = "artist_format";
static const char* const kTitleFormat = "title_format";
static const char* const kAlbumFormat = "album_format";
static const char* const kAlbumArtistFormat = "album_artist_format";
static const char* const kTrackNumberFormat = "track_number_format";
static const char* const kSkipFormat = "skip_format";

// Default titleformat patterns
static const char* const kDefaultArtistFormat = "[%artist%]";
static const char* const kDefaultTitleFormat = "[%title%]";
static const char* const kDefaultAlbumFormat = "[%album%]";
static const char* const kDefaultAlbumArtistFormat = "[%album artist%]";
static const char* const kDefaultTrackNumberFormat = "[%tracknumber%]";
static const char* const kDefaultSkipFormat = "";  // Empty = don't skip

// Helper functions

/// Get full key with prefix
inline pfc::string8 getFullKey(const char* key) {
    pfc::string8 fullKey;
    fullKey << kPrefix << key;
    return fullKey;
}

/// Get boolean config value with default
inline bool getConfigBool(const char* key, bool defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        return store->getConfigBool(getFullKey(key).c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

/// Set boolean config value
inline void setConfigBool(const char* key, bool value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigBool(getFullKey(key).c_str(), value);
    } catch (...) {}
}

/// Get integer config value with default
inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        return store->getConfigInt(getFullKey(key).c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

/// Set integer config value
inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigInt(getFullKey(key).c_str(), value);
    } catch (...) {}
}

/// Get string config value with default
inline std::string getConfigString(const char* key, const char* defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        fb2k::stringRef result = store->getConfigString(getFullKey(key).c_str(), defaultVal);
        if (result.is_valid()) {
            return result->c_str();
        }
        return defaultVal;
    } catch (...) {
        return defaultVal;
    }
}

/// Set string config value
inline void setConfigString(const char* key, const std::string& value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigString(getFullKey(key).c_str(), value.c_str());
    } catch (...) {}
}

// Convenience accessors

inline bool isScrobblingEnabled() {
    return getConfigBool(kEnableScrobbling, true);
}

inline void setScrobblingEnabled(bool enabled) {
    setConfigBool(kEnableScrobbling, enabled);
}

inline bool isNowPlayingEnabled() {
    return getConfigBool(kEnableNowPlaying, true);
}

inline void setNowPlayingEnabled(bool enabled) {
    setConfigBool(kEnableNowPlaying, enabled);
}

inline bool isLibraryOnlyEnabled() {
    return getConfigBool(kSubmitOnlyInLibrary, false);
}

inline void setLibraryOnlyEnabled(bool enabled) {
    setConfigBool(kSubmitOnlyInLibrary, enabled);
}

inline bool isDynamicSourcesEnabled() {
    return getConfigBool(kSubmitDynamicSources, true);
}

inline void setDynamicSourcesEnabled(bool enabled) {
    setConfigBool(kSubmitDynamicSources, enabled);
}

inline std::string getArtistFormat() {
    return getConfigString(kArtistFormat, kDefaultArtistFormat);
}

inline std::string getTitleFormat() {
    return getConfigString(kTitleFormat, kDefaultTitleFormat);
}

inline std::string getAlbumFormat() {
    return getConfigString(kAlbumFormat, kDefaultAlbumFormat);
}

} // namespace scrobble_config
