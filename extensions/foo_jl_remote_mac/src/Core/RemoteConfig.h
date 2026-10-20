//
//  RemoteConfig.h
//  foo_jl_remote_mac
//
//  Configuration GUIDs, defaults, and fb2k::configStore accessors.
//  Config is persisted via fb2k::configStore (cfg_var does not persist on macOS v2).
//

#pragma once

#include "../fb2k_sdk.h"

namespace remote_config {

// Preferences page GUID
static const GUID guid_preferences_page = {
    0x5E0C7A41, 0x93B2, 0x4D6F,
    {0xA1, 0x8E, 0x27, 0xC4, 0x5B, 0x90, 0x3D, 0x16}
};

// --- Defaults ---
constexpr bool kDefaultEnabled = true;
constexpr int  kDefaultPort    = 8890;
constexpr int  kMinPort        = 1024;      // Below this needs root
constexpr int  kMaxPort        = 65535;

// --- Config keys (stored under kConfigPrefix) ---
static const char* const kConfigPrefix = "foo_jl_remote.";
static const char* const kKeyEnabled   = "enabled";
static const char* const kKeyPort      = "port";

// --- configStore accessors ---
inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
    try {
        auto store = fb2k::configStore::get();
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
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        store->setConfigInt(fullKey.c_str(), value);
    } catch (...) {
    }
}

inline bool isEnabled() {
    return getConfigInt(kKeyEnabled, kDefaultEnabled ? 1 : 0) != 0;
}

inline void setEnabled(bool on) {
    setConfigInt(kKeyEnabled, on ? 1 : 0);
}

// Stored values are user-editable; fall back to the default when out of range.
inline int port() {
    const int64_t v = getConfigInt(kKeyPort, kDefaultPort);
    return (v < kMinPort || v > kMaxPort) ? kDefaultPort : (int)v;
}

inline void setPort(int value) {
    setConfigInt(kKeyPort, value);
}

} // namespace remote_config
