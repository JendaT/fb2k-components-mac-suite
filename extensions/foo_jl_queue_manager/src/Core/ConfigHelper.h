//
//  ConfigHelper.h
//  foo_jl_queue_manager
//
//  Header-only config wrapper for fb2k::configStore
//  Use this instead of cfg_var which doesn't persist on macOS v2
//

#pragma once

#include <foobar2000/SDK/foobar2000.h>

namespace queue_config {

// Config key prefix for this component
static const char* const kConfigPrefix = "foo_jl_queue_manager.";

// Get integer config value with default
inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
    pfc::string8 fullKey;
    fullKey << kConfigPrefix << key;
    return fb2k::configStore::get()->getConfigInt(fullKey.c_str(), defaultVal);
}

// Set integer config value
inline void setConfigInt(const char* key, int64_t value) {
    pfc::string8 fullKey;
    fullKey << kConfigPrefix << key;
    fb2k::configStore::get()->setConfigInt(fullKey.c_str(), value);
}

// Get string config value with default
inline pfc::string8 getConfigString(const char* key, const char* defaultVal) {
    pfc::string8 fullKey;
    fullKey << kConfigPrefix << key;
    fb2k::stringRef result = fb2k::configStore::get()->getConfigString(fullKey.c_str(), defaultVal);
    return pfc::string8(result->c_str());
}

// Set string config value
inline void setConfigString(const char* key, const char* value) {
    pfc::string8 fullKey;
    fullKey << kConfigPrefix << key;
    fb2k::configStore::get()->setConfigString(fullKey.c_str(), value);
}

// Get bool config value (stored as int)
inline bool getConfigBool(const char* key, bool defaultVal) {
    return getConfigInt(key, defaultVal ? 1 : 0) != 0;
}

// Set bool config value (stored as int)
inline void setConfigBool(const char* key, bool value) {
    setConfigInt(key, value ? 1 : 0);
}

} // namespace queue_config
