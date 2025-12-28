//
//  AlbumArtConfig.h
//  foo_jl_album_art_mac
//
//  Configuration system for Album Art (Extended) component
//  Handles per-instance artwork type persistence
//

#pragma once

#include "../fb2k_sdk.h"

namespace albumart_config {

// Artwork type enumeration matching SDK's album_art_ids order
enum class ArtworkType : int {
    Front = 0,   // album_art_ids::cover_front
    Back = 1,    // album_art_ids::cover_back
    Disc = 2,    // album_art_ids::disc
    Icon = 3,    // album_art_ids::icon
    Artist = 4,  // album_art_ids::artist
    Count = 5
};

// Config key prefix for our component
static const char* const kConfigPrefix = "foo_jl_album_art.";

// Convert ArtworkType to SDK GUID
inline GUID artworkTypeToGUID(ArtworkType type) {
    switch (type) {
        case ArtworkType::Front:  return album_art_ids::cover_front;
        case ArtworkType::Back:   return album_art_ids::cover_back;
        case ArtworkType::Disc:   return album_art_ids::disc;
        case ArtworkType::Icon:   return album_art_ids::icon;
        case ArtworkType::Artist: return album_art_ids::artist;
        default:                  return album_art_ids::cover_front;
    }
}

// Convert SDK GUID to ArtworkType
inline ArtworkType guidToArtworkType(const GUID& guid) {
    if (guid == album_art_ids::cover_front) return ArtworkType::Front;
    if (guid == album_art_ids::cover_back)  return ArtworkType::Back;
    if (guid == album_art_ids::disc)        return ArtworkType::Disc;
    if (guid == album_art_ids::icon)        return ArtworkType::Icon;
    if (guid == album_art_ids::artist)      return ArtworkType::Artist;
    return ArtworkType::Front;
}

// Get display name for artwork type
inline const char* artworkTypeName(ArtworkType type) {
    switch (type) {
        case ArtworkType::Front:  return "Front Cover";
        case ArtworkType::Back:   return "Back Cover";
        case ArtworkType::Disc:   return "Disc";
        case ArtworkType::Icon:   return "Icon";
        case ArtworkType::Artist: return "Artist";
        default:                  return "Unknown";
    }
}

// Parse artwork type from string (for layout parameters)
// Supports: "front", "back", "disc", "icon", "artist" (case-insensitive)
inline ArtworkType parseTypeFromString(const char* str) {
    if (!str || !*str) return ArtworkType::Front;

    // Case-insensitive comparison using strcasecmp (POSIX)
    if (strcasecmp(str, "front") == 0 ||
        strcasecmp(str, "front_cover") == 0 ||
        strcasecmp(str, "cover_front") == 0)
        return ArtworkType::Front;
    if (strcasecmp(str, "back") == 0 ||
        strcasecmp(str, "back_cover") == 0 ||
        strcasecmp(str, "cover_back") == 0)
        return ArtworkType::Back;
    if (strcasecmp(str, "disc") == 0 ||
        strcasecmp(str, "cd") == 0 ||
        strcasecmp(str, "media") == 0)
        return ArtworkType::Disc;
    if (strcasecmp(str, "icon") == 0 ||
        strcasecmp(str, "album_icon") == 0)
        return ArtworkType::Icon;
    if (strcasecmp(str, "artist") == 0 ||
        strcasecmp(str, "artist_picture") == 0)
        return ArtworkType::Artist;

    return ArtworkType::Front;
}

// Helper functions for reading/writing config using fb2k::configStore
inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        return store->getConfigInt(fullKey.c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

inline void setConfigInt(const char* key, int64_t value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        store->setConfigInt(fullKey.c_str(), value);
    } catch (...) {
        // Silently fail
    }
}

inline pfc::string8 getConfigString(const char* key, const char* defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return pfc::string8(defaultVal);
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        pfc::string8 result;
        store->getConfigString(fullKey.c_str(), result);
        if (result.is_empty()) return pfc::string8(defaultVal);
        return result;
    } catch (...) {
        return pfc::string8(defaultVal);
    }
}

inline void setConfigString(const char* key, const char* value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        store->setConfigString(fullKey.c_str(), value);
    } catch (...) {
        // Silently fail
    }
}

// Per-instance artwork type storage
// Key format: "instance.<instanceGUID>.type"

inline ArtworkType getInstanceType(const char* instanceGUID, ArtworkType defaultType) {
    pfc::string8 key;
    key << "instance." << instanceGUID << ".type";
    int64_t val = getConfigInt(key.c_str(), static_cast<int64_t>(defaultType));
    if (val < 0 || val >= static_cast<int64_t>(ArtworkType::Count)) {
        return defaultType;
    }
    return static_cast<ArtworkType>(val);
}

inline void setInstanceType(const char* instanceGUID, ArtworkType type) {
    pfc::string8 key;
    key << "instance." << instanceGUID << ".type";
    setConfigInt(key.c_str(), static_cast<int64_t>(type));
}

// Check if instance has a saved type (returns false if using default)
inline bool hasInstanceType(const char* instanceGUID) {
    pfc::string8 key;
    key << "instance." << instanceGUID << ".type";
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return false;
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        // Try to get the value - if it returns the default, we check if it was actually set
        // Unfortunately configStore doesn't have a "has key" method, so we use a sentinel
        int64_t sentinel = -999;
        int64_t val = store->getConfigInt(fullKey.c_str(), sentinel);
        return val != sentinel;
    } catch (...) {
        return false;
    }
}

// Generate a new instance GUID
inline pfc::string8 generateInstanceGUID() {
    GUID guid = pfc::createGUID();
    pfc::string8 result;
    result << pfc::print_guid(guid);
    return result;
}

} // namespace albumart_config
