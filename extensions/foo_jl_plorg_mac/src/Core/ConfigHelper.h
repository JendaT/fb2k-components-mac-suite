//
//  ConfigHelper.h
//  foo_plorg_mac
//
//  Helper for accessing fb2k::configStore API for persistent configuration
//

#pragma once

#include "../fb2k_sdk.h"
#import <Foundation/Foundation.h>

namespace plorg_config {

// Config key prefix for our component
static const char* const kConfigPrefix = "foo_plorg.";

// Config keys (stored in configStore)
static const char* const kExpandedFolders = "expanded_folders";      // JSON array of paths
static const char* const kNodeFormat = "node_format";                // Title format pattern

// File-based config
static const char* const kTreeFileName = "foo_plorg.yaml";           // Tree structure file
static const char* const kSingleClickActivate = "single_click_activate";
static const char* const kDoubleClickPlay = "double_click_play";
static const char* const kAutoRevealPlaying = "auto_reveal_playing";
static const char* const kShowIcons = "show_icons";
static const char* const kSyncPlaylists = "sync_playlists";           // Auto-sync with foobar playlists
static const char* const kShowTreeLines = "show_tree_lines";           // Show tree connection lines

// Default values
static const char* const kDefaultNodeFormat = "%node_name%$if(%is_folder%,' ['%count%']',)";
static const bool kDefaultSingleClickActivate = false;
static const bool kDefaultDoubleClickPlay = true;
static const bool kDefaultAutoRevealPlaying = true;
static const bool kDefaultShowIcons = true;
static const bool kDefaultSyncPlaylists = true;
static const bool kDefaultShowTreeLines = true;

// Integer config
inline int64_t getConfigInt(const char* key, int64_t defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        return store->getConfigInt(fullKey.c_str(), defaultVal);
    } catch (...) {
        FB2K_console_formatter() << "[Plorg] getConfigInt exception for key: " << key;
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
        FB2K_console_formatter() << "[Plorg] setConfigInt exception for key: " << key;
    }
}

// Boolean config
inline bool getConfigBool(const char* key, bool defaultVal) {
    return getConfigInt(key, defaultVal ? 1 : 0) != 0;
}

inline void setConfigBool(const char* key, bool value) {
    setConfigInt(key, value ? 1 : 0);
}

// String config
inline NSString* getConfigString(const char* key, const char* defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;

        fb2k::stringRef value = store->getConfigString(fullKey.c_str());
        if (value.is_valid() && value->length() > 0) {
            return [NSString stringWithUTF8String:value->c_str()];
        }
        return defaultVal ? [NSString stringWithUTF8String:defaultVal] : @"";
    } catch (...) {
        FB2K_console_formatter() << "[Plorg] getConfigString exception for key: " << key;
        return defaultVal ? [NSString stringWithUTF8String:defaultVal] : @"";
    }
}

inline void setConfigString(const char* key, NSString* value) {
    try {
        auto store = fb2k::configStore::get();
        pfc::string8 fullKey;
        fullKey << kConfigPrefix << key;
        store->setConfigString(fullKey.c_str(), value ? [value UTF8String] : "");
    } catch (...) {
        FB2K_console_formatter() << "[Plorg] setConfigString exception for key: " << key;
    }
}

// File-based config helpers
inline NSString* getConfigFilePath() {
    // Store in ~/Library/foobar2000-v2/foo_plorg.yaml
    NSString *homeDir = NSHomeDirectory();
    NSString *configDir = [homeDir stringByAppendingPathComponent:@"Library/foobar2000-v2"];

    // Ensure directory exists
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:configDir]) {
        [fm createDirectoryAtPath:configDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    return [configDir stringByAppendingPathComponent:@(kTreeFileName)];
}

inline NSString* loadTreeFromFile() {
    NSString *path = getConfigFilePath();
    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        return nil;
    }
    return content;
}

inline BOOL saveTreeToFile(NSString* yaml) {
    NSString *path = getConfigFilePath();
    NSError *error = nil;
    BOOL success = [yaml writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!success) {
        FB2K_console_formatter() << "[Plorg] Failed to save tree file: " << [[error localizedDescription] UTF8String];
    }
    return success;
}

} // namespace plorg_config
