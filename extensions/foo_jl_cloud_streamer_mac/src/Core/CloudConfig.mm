//
//  CloudConfig.mm
//  foo_jl_cloud_streamer_mac
//
//  Configuration storage using fb2k::configStore (persists on macOS)
//

#import <Foundation/Foundation.h>
#include "CloudConfig.h"

namespace cloud_streamer {

pfc::string8 CloudConfig::getFullKey(const char* key) {
    pfc::string8 fullKey;
    fullKey << kConfigPrefix << key;
    return fullKey;
}

bool CloudConfig::getConfigBool(const char* key, bool defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        return store->getConfigBool(getFullKey(key).c_str(), defaultVal);
    } catch (...) {
        return defaultVal;
    }
}

int CloudConfig::getConfigInt(const char* key, int defaultVal) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return defaultVal;
        return static_cast<int>(store->getConfigInt(getFullKey(key).c_str(), defaultVal));
    } catch (...) {
        return defaultVal;
    }
}

std::string CloudConfig::getConfigString(const char* key, const char* defaultVal) {
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

void CloudConfig::setConfigBool(const char* key, bool value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigBool(getFullKey(key).c_str(), value);
    } catch (...) {
        console::error("[Cloud Streamer] Failed to save config value");
    }
}

void CloudConfig::setConfigInt(const char* key, int value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigInt(getFullKey(key).c_str(), value);
    } catch (...) {
        console::error("[Cloud Streamer] Failed to save config value");
    }
}

void CloudConfig::setConfigString(const char* key, const std::string& value) {
    try {
        auto store = fb2k::configStore::get();
        if (!store.is_valid()) return;
        store->setConfigString(getFullKey(key).c_str(), value.c_str());
    } catch (...) {
        console::error("[Cloud Streamer] Failed to save config value");
    }
}

// Convenience accessors

std::string CloudConfig::getYtDlpPath() {
    std::string path = getConfigString(kYtDlpPath, "");
    if (path.empty()) {
        // Try to auto-detect
        path = detectYtDlpPath();
        if (!path.empty()) {
            setYtDlpPath(path);
        }
    }
    return path;
}

void CloudConfig::setYtDlpPath(const std::string& path) {
    setConfigString(kYtDlpPath, path);
}

MixcloudFormat CloudConfig::getMixcloudFormat() {
    return static_cast<MixcloudFormat>(getConfigInt(kMixcloudFormat, 0));
}

void CloudConfig::setMixcloudFormat(MixcloudFormat format) {
    setConfigInt(kMixcloudFormat, static_cast<int>(format));
}

SoundCloudFormat CloudConfig::getSoundCloudFormat() {
    return static_cast<SoundCloudFormat>(getConfigInt(kSoundCloudFormat, 0));
}

void CloudConfig::setSoundCloudFormat(SoundCloudFormat format) {
    setConfigInt(kSoundCloudFormat, static_cast<int>(format));
}

bool CloudConfig::isCacheEnabled() {
    return getConfigBool(kCacheStreamUrls, true);
}

void CloudConfig::setCacheEnabled(bool enabled) {
    setConfigBool(kCacheStreamUrls, enabled);
}

bool CloudConfig::isDebugLoggingEnabled() {
    return getConfigBool(kDebugLogging, false);
}

void CloudConfig::setDebugLoggingEnabled(bool enabled) {
    setConfigBool(kDebugLogging, enabled);
}

int CloudConfig::getStreamCacheTTL(bool isMixcloud) {
    if (isMixcloud) {
        return getConfigInt(kStreamCacheTTLMixcloud, kDefaultStreamCacheTTLMixcloud);
    } else {
        return getConfigInt(kStreamCacheTTLSoundCloud, kDefaultStreamCacheTTLSoundCloud);
    }
}

void CloudConfig::setStreamCacheTTL(bool isMixcloud, int seconds) {
    if (isMixcloud) {
        setConfigInt(kStreamCacheTTLMixcloud, seconds);
    } else {
        setConfigInt(kStreamCacheTTLSoundCloud, seconds);
    }
}

std::string CloudConfig::detectYtDlpPath() {
    @autoreleasepool {
        // Check standard Homebrew locations (security-approved paths)
        NSArray<NSString*>* searchPaths = @[
            @"/opt/homebrew/bin/yt-dlp",    // Apple Silicon Homebrew
            @"/usr/local/bin/yt-dlp"        // Intel Homebrew
        ];

        NSFileManager* fm = [NSFileManager defaultManager];

        for (NSString* path in searchPaths) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDir] && !isDir) {
                if ([fm isExecutableFileAtPath:path]) {
                    return std::string([path UTF8String]);
                }
            }
        }

        return std::string();
    }
}

} // namespace cloud_streamer
