//
//  TidalConfig.mm
//  foo_jl_tidal_mac
//
//  Configuration storage using fb2k::configStore (persists on macOS)
//

#import <Foundation/Foundation.h>
#include "TidalConfig.h"

namespace tidal {

pfc::string8 TidalConfig::getFullKey(const char* key) {
    pfc::string8 fullKey;
    fullKey << kConfigPrefix << key;
    return fullKey;
}

bool TidalConfig::getConfigBool(const char* key, bool defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        return store->getConfigBool(getFullKey(key).c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

int TidalConfig::getConfigInt(const char* key, int defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        return static_cast<int>(store->getConfigInt(getFullKey(key).c_str(), defaultVal));
    } catch (...) {
        return defaultVal;
    }
}

std::string TidalConfig::getConfigString(const char* key, const char* defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return std::string(defaultVal);
        fb2k::stringRef result = store->getConfigString(getFullKey(key).c_str(), defaultVal);
        if (result.is_valid()) {
            return std::string(result->c_str());
        }
        return std::string(defaultVal);
    } catch (...) {
        return std::string(defaultVal);
    }
}

void TidalConfig::setConfigBool(const char* key, bool value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigBool(getFullKey(key).c_str(), value);
    } catch (...) {
        console::error("[Tidal] Failed to save config value");
    }
}

void TidalConfig::setConfigInt(const char* key, int value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigInt(getFullKey(key).c_str(), value);
    } catch (...) {
        console::error("[Tidal] Failed to save config value");
    }
}

void TidalConfig::setConfigString(const char* key, const std::string& value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigString(getFullKey(key).c_str(), value.c_str());
    } catch (...) {
        console::error("[Tidal] Failed to save config value");
    }
}

// Convenience accessors

JLTidalQuality TidalConfig::getPreferredQuality() {
    return static_cast<JLTidalQuality>(getConfigInt(kPreferredQuality, kDefaultPreferredQuality));
}

void TidalConfig::setPreferredQuality(JLTidalQuality quality) {
    setConfigInt(kPreferredQuality, static_cast<int>(quality));
}

bool TidalConfig::isDebugLoggingEnabled() {
    return getConfigBool(kDebugLogging, kDefaultDebugLogging);
}

void TidalConfig::setDebugLoggingEnabled(bool enabled) {
    setConfigBool(kDebugLogging, enabled);
    refreshDebugLoggingCache();
}

bool TidalConfig::isCacheEnabled() {
    return getConfigBool(kCacheStreamUrls, kDefaultCacheStreamUrls);
}

void TidalConfig::setCacheEnabled(bool enabled) {
    setConfigBool(kCacheStreamUrls, enabled);
}

bool TidalConfig::isDASHEnabled() {
    return getConfigBool(kDASHEnabled, kDefaultDASHEnabled);
}

void TidalConfig::setDASHEnabled(bool enabled) {
    setConfigBool(kDASHEnabled, enabled);
}

std::string TidalConfig::getLibraryRoot() {
    return getConfigString(kLibraryRoot, "");
}

void TidalConfig::setLibraryRoot(const std::string& path) {
    setConfigString(kLibraryRoot, path);
}

std::string TidalConfig::getGenreMapJSON() {
    return getConfigString(kGenreMap, "{}");
}

void TidalConfig::setGenreMapJSON(const std::string& json) {
    setConfigString(kGenreMap, json);
}

} // namespace tidal
