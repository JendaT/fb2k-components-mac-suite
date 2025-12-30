# foo_jl_cloud_streamer - Implementation Plan

## Overview

This document outlines the implementation phases for the foobar2000 macOS cloud streaming component.

**Target Platform**: macOS (foobar2000 v2 for Mac)
**Development Environment**: Xcode with Objective-C++
**SDK**: foobar2000 macOS SDK (SDK-2025-03-07)

---

## Critical Architecture Requirements

Before implementation begins, these patterns must be established:

### 1. Abort Callback Infrastructure
All long-running operations must accept and respect abort signals:
```objc
- (NSString *)executeWithAbortFlag:(std::atomic<bool> *)abort
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error;
```

### 2. Thread-Safe Caches
All caches must use dispatch queue isolation:
```objc
@property (nonatomic, strong) dispatch_queue_t isolationQueue;
```

### 3. Configuration Storage
Use `fb2k::configStore` (NOT `cfg_var_legacy`):
```objc
fb2k::configStore::get()->getString(key, defaultValue);
```

### 4. Non-Blocking Stream Resolution
The `open()` path must check cache first (fast) and only block on yt-dlp when necessary with proper abort handling.

---

## Phase 1: Project Setup

### 1.1 Create Directory Structure
```
foo_jl_cloud_streamer_mac/
├── Scripts/
│   ├── build.sh
│   ├── install.sh
│   ├── clean.sh
│   └── generate_xcode_project.rb
├── Resources/
│   └── Info.plist
├── src/
│   ├── fb2k_sdk.h
│   ├── Prefix.pch
│   ├── Core/
│   ├── Services/
│   ├── Integration/
│   └── UI/
└── README.md
```

### 1.2 Set Up Build Scripts
- Copy and adapt `build.sh` from foo_jl_scrobble_mac
- Copy and adapt `install.sh`
- Copy and adapt `clean.sh`
- Adapt `generate_xcode_project.rb` for this component

### 1.3 Create SDK Wrapper
```cpp
// fb2k_sdk.h
#pragma once

#define FOOBAR2000_HAVE_CFG_VAR_LEGACY 1
#include <foobar2000/SDK/foobar2000.h>
#include <foobar2000/helpers/input_helpers.h>
```

### 1.4 Create Precompiled Header
```objc
// Prefix.pch
#pragma once

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#endif

#include "fb2k_sdk.h"
```

### 1.5 Verification
- [ ] Xcode project generates successfully
- [ ] Empty component builds
- [ ] Component loads in foobar2000

---

## Phase 2: YtDlpWrapper with Abort Support

**Critical**: This phase establishes the abort callback pattern used throughout.

### 2.1 Error Codes (`Core/CloudErrors.h`)
```objc
typedef NS_ENUM(NSInteger, JLCloudError) {
    JLErrorNone = 0,
    JLErrorCancelled = 1,
    JLErrorTimeout = 2,
    JLErrorYtDlpNotFound = 10,
    JLErrorYtDlpFailed = 11,
    JLErrorNetworkError = 20,
    JLErrorGeoRestricted = 21,
    JLErrorTrackUnavailable = 22,
    JLErrorStreamExpired = 30,
    JLErrorUnsupportedURL = 40,
};

extern NSErrorDomain const JLCloudErrorDomain;
```

### 2.2 YtDlpWrapper Interface (`Services/YtDlpWrapper.h`)
```objc
@interface JLYtDlpWrapper : NSObject

+ (instancetype)shared;

// Path management with security validation
- (NSString *)executablePath;
- (void)setCustomPath:(NSString *)path;

// Availability check
- (BOOL)isAvailable;
- (NSString *)version;

// Core execution with abort support
- (NSString *)executeWithArguments:(NSArray<NSString *> *)args
                         abortFlag:(std::atomic<bool> *)abort
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error;

// High-level operations
- (JLTrackInfo *)extractInfoForURL:(NSString *)url
                         abortFlag:(std::atomic<bool> *)abort
                             error:(NSError **)error;

- (NSString *)streamURLForURL:(NSString *)url
                     formatId:(NSString *)formatId
                    abortFlag:(std::atomic<bool> *)abort
                        error:(NSError **)error;

- (NSArray<JLPlaylistEntry *> *)playlistEntriesForURL:(NSString *)url
                                                limit:(int)limit
                                            abortFlag:(std::atomic<bool> *)abort
                                                error:(NSError **)error;

@end
```

### 2.3 Path Validation (Security)
```objc
- (BOOL)isValidYtDlpBinary:(NSString *)path {
    if (!path || path.length == 0) return NO;

    // Must be absolute path
    if (![path hasPrefix:@"/"]) return NO;

    // Must exist and be executable
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:path]) return NO;

    // Verify it's actually yt-dlp by checking version output
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = @[@"--version"];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return NO;
    [task waitUntilExit];

    if (task.terminationStatus != 0) return NO;

    // Check output matches YYYY.MM.DD pattern
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *version = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"^\\d{4}\\.\\d{2}\\.\\d{2}"
        options:0 error:nil];
    return [regex firstMatchInString:version options:0
                               range:NSMakeRange(0, version.length)] != nil;
}

- (NSString *)findYtDlpPath {
    // 1. Check custom path from preferences
    NSString *customPath = cloud_config::getYtDlpPath();
    if ([self isValidYtDlpBinary:customPath]) {
        return customPath;
    }

    // 2. Check Homebrew paths (known safe locations)
    NSArray *searchPaths = @[
        @"/opt/homebrew/bin/yt-dlp",  // Apple Silicon
        @"/usr/local/bin/yt-dlp",      // Intel
    ];
    for (NSString *path in searchPaths) {
        if ([self isValidYtDlpBinary:path]) {
            return path;
        }
    }

    // Do NOT use PATH lookup for security
    return nil;
}
```

### 2.4 Subprocess Execution (Zombie-Safe)
```objc
- (NSString *)executeWithArguments:(NSArray<NSString *> *)args
                         abortFlag:(std::atomic<bool> *)abort
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:self.executablePath];
    task.arguments = args;

    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    __block BOOL completed = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    task.terminationHandler = ^(NSTask *t) {
        completed = YES;
        dispatch_semaphore_signal(sem);
    };

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (error) *error = launchError;
        return nil;
    }

    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(timeout * NSEC_PER_SEC));

    while (!completed) {
        // Check abort flag
        if (abort && abort->load()) {
            [task terminate];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (error) *error = [NSError errorWithDomain:JLCloudErrorDomain
                                                    code:JLErrorCancelled
                                                userInfo:@{NSLocalizedDescriptionKey: @"Cancelled"}];
            return nil;
        }

        // Wait with short timeout for polling
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) == 0) {
            break;
        }

        // Check timeout
        if (dispatch_time(DISPATCH_TIME_NOW, 0) > deadline) {
            [task terminate];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (error) *error = [NSError errorWithDomain:JLCloudErrorDomain
                                                    code:JLErrorTimeout
                                                userInfo:@{NSLocalizedDescriptionKey: @"Timeout"}];
            return nil;
        }
    }

    if (task.terminationStatus != 0) {
        NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
        NSString *stderrStr = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding];
        if (error) *error = [NSError errorWithDomain:JLCloudErrorDomain
                                                code:JLErrorYtDlpFailed
                                            userInfo:@{NSLocalizedDescriptionKey: stderrStr ?: @"Unknown error"}];
        return nil;
    }

    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    return [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
}
```

### 2.5 JSON Parsing with NSJSONSerialization
```objc
- (JLTrackInfo *)parseTrackInfoFromJSON:(NSString *)jsonString error:(NSError **)error {
    NSData *data = [jsonString dataUsingEncoding:NSUTF8StringEncoding];
    NSError *parseError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:&parseError];
    if (!json) {
        if (error) *error = parseError;
        return nil;
    }

    JLTrackInfo *info = [[JLTrackInfo alloc] init];
    info.trackId = json[@"id"] ?: @"";
    info.title = json[@"title"] ?: @"";
    info.uploader = json[@"uploader"] ?: @"";
    info.uploaderId = json[@"uploader_id"] ?: @"";
    info.thumbnail = json[@"thumbnail"] ?: @"";
    info.webpageUrl = json[@"webpage_url"] ?: @"";
    info.duration = [json[@"duration"] doubleValue];
    info.timestamp = [json[@"timestamp"] longLongValue];

    // Parse tags
    NSArray *tags = json[@"tags"];
    if ([tags isKindOfClass:[NSArray class]]) {
        info.tags = tags;
    }

    // Parse formats
    NSArray *formats = json[@"formats"];
    if ([formats isKindOfClass:[NSArray class]]) {
        NSMutableArray *audioFormats = [NSMutableArray array];
        for (NSDictionary *fmt in formats) {
            JLAudioFormat *af = [[JLAudioFormat alloc] init];
            af.formatId = fmt[@"format_id"] ?: @"";
            af.url = fmt[@"url"] ?: @"";
            af.ext = fmt[@"ext"] ?: @"";
            af.acodec = fmt[@"acodec"] ?: @"";
            af.abr = [fmt[@"abr"] intValue];

            NSString *protocol = fmt[@"protocol"] ?: @"";
            af.isHLS = [protocol containsString:@"m3u8"];
            af.isDASH = [protocol containsString:@"dash"];

            if (af.url.length > 0) {
                [audioFormats addObject:af];
            }
        }
        info.formats = audioFormats;
    }

    // Determine service
    info.isMixcloud = [info.webpageUrl containsString:@"mixcloud.com"];
    info.isSoundCloud = [info.webpageUrl containsString:@"soundcloud.com"];

    return info;
}
```

### 2.6 Verification
- [ ] yt-dlp detection works with security validation
- [ ] Version retrieval works
- [ ] Abort flag properly terminates subprocess
- [ ] Timeout properly terminates subprocess (no zombies)
- [ ] Mixcloud metadata extraction works
- [ ] SoundCloud metadata extraction works
- [ ] Stream URL extraction works

---

## Phase 3: Thread-Safe Caches

### 3.1 StreamCache (`Core/StreamCache.h`)
```objc
@interface JLStreamCache : NSObject

+ (instancetype)shared;

// Thread-safe access
- (NSString *)streamURLForKey:(NSString *)key;
- (void)setStreamURL:(NSString *)url forKey:(NSString *)key isMixcloud:(BOOL)isMixcloud;
- (void)invalidateKey:(NSString *)key;

// Async prefetch
- (void)prefetchURLForTrack:(NSString *)trackURL;

// Maintenance
- (void)cleanupExpired;
- (NSUInteger)count;
- (NSUInteger)expiredCount;

@end
```

### 3.2 StreamCache Implementation
```objc
@interface JLStreamCache ()
@property (nonatomic, strong) dispatch_queue_t isolationQueue;
@end

@implementation JLStreamCache {
    struct CacheEntry {
        std::string url;
        std::chrono::steady_clock::time_point expiresAt;

        bool isExpired() const {
            return std::chrono::steady_clock::now() > expiresAt;
        }
    };
    std::unordered_map<std::string, CacheEntry> _cache;
}

- (instancetype)init {
    if (self = [super init]) {
        _isolationQueue = dispatch_queue_create(
            "com.jl.cloudstreamer.streamcache",
            DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)streamURLForKey:(NSString *)key {
    __block NSString *result = nil;
    dispatch_sync(_isolationQueue, ^{
        auto it = _cache.find(key.UTF8String);
        if (it != _cache.end() && !it->second.isExpired()) {
            result = @(it->second.url.c_str());
        }
    });
    return result;
}

- (void)setStreamURL:(NSString *)url forKey:(NSString *)key isMixcloud:(BOOL)isMixcloud {
    dispatch_async(_isolationQueue, ^{
        CacheEntry entry;
        entry.url = url.UTF8String;

        auto ttl = isMixcloud
            ? std::chrono::hours(4)
            : std::chrono::hours(2);
        entry.expiresAt = std::chrono::steady_clock::now() + ttl;

        _cache[key.UTF8String] = entry;
    });
}

- (void)invalidateKey:(NSString *)key {
    dispatch_async(_isolationQueue, ^{
        _cache.erase(key.UTF8String);
    });
}

- (void)cleanupExpired {
    dispatch_async(_isolationQueue, ^{
        auto now = std::chrono::steady_clock::now();
        for (auto it = _cache.begin(); it != _cache.end(); ) {
            if (now > it->second.expiresAt) {
                it = _cache.erase(it);
            } else {
                ++it;
            }
        }
    });
}

@end
```

### 3.3 MetadataCache (`Core/MetadataCache.h`)
```objc
@interface JLMetadataCache : NSObject

+ (instancetype)shared;

- (void)setCachePath:(NSString *)path;

// Thread-safe access with optional freshness
- (JLTrackInfo *)trackInfoForURL:(NSString *)url;
- (JLTrackInfo *)trackInfoForURL:(NSString *)url maxAge:(NSTimeInterval)maxAge;
- (void)setTrackInfo:(JLTrackInfo *)info forURL:(NSString *)url;

- (BOOL)containsURL:(NSString *)url;
- (void)removeURL:(NSString *)url;
- (void)clear;

- (BOOL)loadFromDisk;
- (BOOL)saveToDisk;

- (NSUInteger)count;

@end
```

### 3.4 MetadataCache with Version Migration
```objc
- (BOOL)loadFromDisk {
    if (!_cachePath) return NO;

    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfFile:_cachePath options:0 error:&error];
    if (!data) {
        // File doesn't exist yet - OK
        return YES;
    }

    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:&error];
    if (!json) {
        console::warning("Cloud Streamer: Failed to parse cache file");
        return NO;
    }

    NSInteger version = [json[@"version"] integerValue];
    switch (version) {
        case 1:
            return [self loadV1Data:json];
        default:
            console::warning("Cloud Streamer: Unknown cache version, resetting");
            [self clear];
            return NO;
    }
}

- (BOOL)loadV1Data:(NSDictionary *)json {
    NSDictionary *tracks = json[@"tracks"];
    if (![tracks isKindOfClass:[NSDictionary class]]) {
        return YES;  // Empty cache
    }

    dispatch_sync(_isolationQueue, ^{
        for (NSString *url in tracks) {
            NSDictionary *entry = tracks[url];
            NSDictionary *infoDict = entry[@"info"];
            int64_t cachedAt = [entry[@"cached_at"] longLongValue];

            JLTrackInfo *info = [self trackInfoFromDictionary:infoDict];
            if (info) {
                CacheEntry ce;
                ce.info = info;
                ce.cachedAt = cachedAt;
                _cache[url.UTF8String] = ce;
            }
        }
    });

    return YES;
}
```

### 3.5 ThumbnailCache (Async)
```objc
@interface JLThumbnailCache : NSObject

+ (instancetype)shared;

// Returns local path if cached, nil if not
- (NSString *)localPathForThumbnailURL:(NSString *)url;

// Async download
- (void)downloadThumbnailAsync:(NSString *)url
                    completion:(void(^)(NSString *localPath, NSError *error))completion;

- (void)clearCache;
- (NSUInteger)diskUsage;

@end

@implementation JLThumbnailCache

- (NSString *)localPathForThumbnailURL:(NSString *)url {
    NSString *hash = [self hashForURL:url];
    NSString *path = [self.cacheDirectory stringByAppendingPathComponent:hash];

    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return path;
    }
    return nil;
}

- (void)downloadThumbnailAsync:(NSString *)url
                    completion:(void(^)(NSString *localPath, NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL *imageURL = [NSURL URLWithString:url];
        NSData *data = [NSData dataWithContentsOfURL:imageURL];

        if (!data) {
            if (completion) {
                completion(nil, [NSError errorWithDomain:JLCloudErrorDomain
                                                    code:JLErrorNetworkError
                                                userInfo:nil]);
            }
            return;
        }

        NSString *hash = [self hashForURL:url];
        NSString *path = [self.cacheDirectory stringByAppendingPathComponent:hash];

        NSError *writeError = nil;
        if ([data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
            if (completion) {
                completion(path, nil);
            }
        } else {
            if (completion) {
                completion(nil, writeError);
            }
        }
    });
}

- (NSString *)hashForURL:(NSString *)url {
    // SHA256 hash of URL
    NSData *data = [url dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);

    NSMutableString *result = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [result appendFormat:@"%02x", hash[i]];
    }
    return result;
}

@end
```

### 3.6 Verification
- [ ] StreamCache thread-safe access
- [ ] StreamCache TTL expiration
- [ ] MetadataCache persistence
- [ ] MetadataCache version migration
- [ ] ThumbnailCache async download
- [ ] ThumbnailCache disk storage

---

## Phase 4: Configuration & URL Utils

### 4.1 Configuration (`Core/CloudConfig.h`)
```cpp
namespace cloud_config {
    static const char* const kPrefix = "foo_jl_cloud_streamer.";

    std::string getYtDlpPath();
    void setYtDlpPath(const std::string& path);

    std::string getMixcloudFormat();
    void setMixcloudFormat(const std::string& format);

    std::string getSoundCloudFormat();
    void setSoundCloudFormat(const std::string& format);

    bool isCacheEnabled();
    void setCacheEnabled(bool enabled);

    bool isDebugEnabled();
    void setDebugEnabled(bool enabled);
}
```

### 4.2 Configuration Implementation
```cpp
namespace cloud_config {
    std::string getYtDlpPath() {
        pfc::string8 key(kPrefix);
        key += "ytdlp_path";
        return fb2k::configStore::get()->getString(key, "").get_ptr();
    }

    void setYtDlpPath(const std::string& path) {
        pfc::string8 key(kPrefix);
        key += "ytdlp_path";
        fb2k::configStore::get()->setString(key, path.c_str());
    }

    std::string getMixcloudFormat() {
        pfc::string8 key(kPrefix);
        key += "mixcloud_format";
        return fb2k::configStore::get()->getString(key, "http").get_ptr();
    }

    std::string getSoundCloudFormat() {
        pfc::string8 key(kPrefix);
        key += "soundcloud_format";
        return fb2k::configStore::get()->getString(key, "hls_aac_160k").get_ptr();
    }

    bool isCacheEnabled() {
        pfc::string8 key(kPrefix);
        key += "cache_enabled";
        return fb2k::configStore::get()->getBool(key, true);
    }

    bool isDebugEnabled() {
        pfc::string8 key(kPrefix);
        key += "debug";
        return fb2k::configStore::get()->getBool(key, false);
    }
}
```

### 4.3 URL Utilities (`Core/URLUtils.h`)
```objc
typedef NS_ENUM(NSInteger, JLCloudURLType) {
    JLCloudURLTypeUnknown,
    JLCloudURLTypeTrack,
    JLCloudURLTypePlaylist,
    JLCloudURLTypeProfile,
};

// URL type detection
JLCloudURLType JLDetectURLType(NSString *url);
BOOL JLIsMixcloudURL(NSString *url);
BOOL JLIsSoundCloudURL(NSString *url);
BOOL JLIsSupportedURL(NSString *url);

// URL conversion
NSString *JLToInternalURL(NSString *webUrl);
NSString *JLToWebURL(NSString *internalUrl);
```

### 4.4 URL Utilities Implementation
```objc
JLCloudURLType JLDetectURLType(NSString *url) {
    if (!JLIsSupportedURL(url)) {
        return JLCloudURLTypeUnknown;
    }

    // Extract path
    NSString *path = nil;
    if ([url containsString:@"mixcloud.com/"]) {
        NSRange range = [url rangeOfString:@"mixcloud.com/"];
        path = [url substringFromIndex:NSMaxRange(range)];
    } else if ([url containsString:@"soundcloud.com/"]) {
        NSRange range = [url rangeOfString:@"soundcloud.com/"];
        path = [url substringFromIndex:NSMaxRange(range)];
    } else if ([url hasPrefix:@"mixcloud://"]) {
        path = [url substringFromIndex:11];
    } else if ([url hasPrefix:@"soundcloud://"]) {
        path = [url substringFromIndex:13];
    }

    if (!path) return JLCloudURLTypeUnknown;

    // Remove trailing slash
    if ([path hasSuffix:@"/"]) {
        path = [path substringToIndex:path.length - 1];
    }

    // Count path segments
    NSArray *segments = [path componentsSeparatedByString:@"/"];
    segments = [segments filteredArrayUsingPredicate:
                [NSPredicate predicateWithFormat:@"length > 0"]];

    // Check for playlist/set keywords
    if ([path containsString:@"/playlists/"] ||
        [path containsString:@"/sets/"] ||
        [path containsString:@"/albums/"]) {
        return JLCloudURLTypePlaylist;
    }

    // Single segment = user profile
    if (segments.count == 1) {
        return JLCloudURLTypeProfile;
    }

    // Two segments = track
    if (segments.count == 2) {
        return JLCloudURLTypeTrack;
    }

    return JLCloudURLTypeUnknown;
}

BOOL JLIsMixcloudURL(NSString *url) {
    return [url containsString:@"mixcloud.com/"] ||
           [url hasPrefix:@"mixcloud://"];
}

BOOL JLIsSoundCloudURL(NSString *url) {
    return [url containsString:@"soundcloud.com/"] ||
           [url hasPrefix:@"soundcloud://"];
}

BOOL JLIsSupportedURL(NSString *url) {
    return JLIsMixcloudURL(url) || JLIsSoundCloudURL(url);
}

NSString *JLToInternalURL(NSString *webUrl) {
    NSString *result = nil;

    if ([webUrl containsString:@"mixcloud.com/"]) {
        NSRange range = [webUrl rangeOfString:@"mixcloud.com/"];
        result = [@"mixcloud://" stringByAppendingString:
                  [webUrl substringFromIndex:NSMaxRange(range)]];
    } else if ([webUrl containsString:@"soundcloud.com/"]) {
        NSRange range = [webUrl rangeOfString:@"soundcloud.com/"];
        result = [@"soundcloud://" stringByAppendingString:
                  [webUrl substringFromIndex:NSMaxRange(range)]];
    } else {
        return webUrl;
    }

    // Remove trailing slash
    if ([result hasSuffix:@"/"]) {
        result = [result substringToIndex:result.length - 1];
    }

    return result;
}

NSString *JLToWebURL(NSString *internalUrl) {
    if ([internalUrl hasPrefix:@"mixcloud://"]) {
        return [@"https://www.mixcloud.com/" stringByAppendingString:
                [internalUrl substringFromIndex:11]];
    } else if ([internalUrl hasPrefix:@"soundcloud://"]) {
        return [@"https://soundcloud.com/" stringByAppendingString:
                [internalUrl substringFromIndex:13]];
    }
    return internalUrl;
}
```

### 4.5 Verification
- [ ] Configuration persists across restarts
- [ ] URL type detection works for all cases
- [ ] Profile URLs detected correctly
- [ ] Playlist URLs detected correctly
- [ ] Track URLs detected correctly

---

## Phase 5: Stream Resolver

### 5.1 StreamResolver Interface (`Services/StreamResolver.h`)
```objc
@interface JLStreamResolver : NSObject

+ (instancetype)shared;

// Sync resolution with abort support
- (NSString *)resolveURL:(NSString *)url
               abortFlag:(std::atomic<bool> *)abort
                   error:(NSError **)error;

// Bypass cache (for re-resolution on 403)
- (NSString *)resolveURLBypassCache:(NSString *)url
                          abortFlag:(std::atomic<bool> *)abort
                              error:(NSError **)error;

// Async prefetch
- (void)prefetchURL:(NSString *)url;

@end
```

### 5.2 StreamResolver Implementation
```objc
@implementation JLStreamResolver

- (NSString *)resolveURL:(NSString *)url
               abortFlag:(std::atomic<bool> *)abort
                   error:(NSError **)error {
    // Check cache first (fast path)
    NSString *cached = [[JLStreamCache shared] streamURLForKey:url];
    if (cached) {
        return cached;
    }

    // Resolve via yt-dlp (slow path)
    return [self resolveURLBypassCache:url abortFlag:abort error:error];
}

- (NSString *)resolveURLBypassCache:(NSString *)url
                          abortFlag:(std::atomic<bool> *)abort
                              error:(NSError **)error {
    NSString *webUrl = JLToWebURL(url);
    BOOL isMixcloud = JLIsMixcloudURL(url);

    // Determine format
    NSString *formatId = isMixcloud
        ? @(cloud_config::getMixcloudFormat().c_str())
        : @(cloud_config::getSoundCloudFormat().c_str());

    NSError *ytError = nil;
    NSString *streamUrl = [[JLYtDlpWrapper shared]
        streamURLForURL:webUrl
               formatId:formatId
              abortFlag:abort
                  error:&ytError];

    if (!streamUrl) {
        // Try without format specifier
        streamUrl = [[JLYtDlpWrapper shared]
            streamURLForURL:webUrl
                   formatId:nil
                  abortFlag:abort
                      error:&ytError];
    }

    if (!streamUrl) {
        if (error) *error = ytError;
        return nil;
    }

    // Cache the result
    [[JLStreamCache shared] setStreamURL:streamUrl forKey:url isMixcloud:isMixcloud];

    return streamUrl;
}

- (void)prefetchURL:(NSString *)url {
    // Check if already cached
    if ([[JLStreamCache shared] streamURLForKey:url]) {
        return;
    }

    // Async prefetch
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        std::atomic<bool> abort{false};
        NSError *error = nil;
        [self resolveURL:url abortFlag:&abort error:&error];
        // Ignore errors - this is best-effort prefetch
    });
}

@end
```

### 5.3 Verification
- [ ] Cache hit returns immediately
- [ ] Cache miss resolves via yt-dlp
- [ ] Abort cancels resolution
- [ ] Bypass cache forces fresh resolution
- [ ] Prefetch runs async

---

## Phase 6: Input Decoder with Re-Resolution

### 6.1 Input Entry (`Integration/CloudInputDecoder.mm`)
```cpp
class cloud_input_entry : public input_entry {
public:
    bool is_our_content_type(const char* p_type) override {
        return false;
    }

    bool is_our_path(const char* p_path, const char* p_ext) override {
        @autoreleasepool {
            NSString *path = [NSString stringWithUTF8String:p_path];
            return [path hasPrefix:@"mixcloud://"] ||
                   [path hasPrefix:@"soundcloud://"];
        }
    }

    void open_for_decoding(service_ptr_t<input_decoder>& out,
                           service_ptr_t<file> filehint,
                           const char* path,
                           abort_callback& abort) override {
        out = new service_impl_t<cloud_input_decoder>();
        out->open(filehint, path, input_open_decode, abort);
    }

    // ... other overrides
};
```

### 6.2 Decoder with Expiration Recovery
```cpp
class cloud_input_decoder : public input_decoder {
private:
    service_ptr_t<input_decoder> m_decoder;
    pfc::string8 m_path;
    pfc::string8 m_stream_url;
    std::atomic<bool> m_abortFlag{false};
    input_open_reason m_reason;
    int m_reresolutionAttempts = 0;
    static constexpr int MAX_RERESOLUTION_ATTEMPTS = 2;

public:
    void open(service_ptr_t<file> filehint,
              const char* path,
              input_open_reason reason,
              abort_callback& abort) override {
        m_path = path;
        m_reason = reason;
        m_abortFlag = false;

        @autoreleasepool {
            NSString *nsPath = [NSString stringWithUTF8String:path];

            // Fast path: check cache
            NSString *cached = [[JLStreamCache shared] streamURLForKey:nsPath];
            if (cached) {
                m_stream_url = cached.UTF8String;
                openUnderlying(abort);
                return;
            }

            // Slow path: resolve with abort support
            NSError *error = nil;
            NSString *streamUrl = [[JLStreamResolver shared]
                resolveURL:nsPath
                 abortFlag:&m_abortFlag
                     error:&error];

            if (abort.is_aborting()) {
                throw exception_aborted();
            }

            if (!streamUrl) {
                throw exception_io_data(error.localizedDescription.UTF8String);
            }

            m_stream_url = streamUrl.UTF8String;
            openUnderlying(abort);
        }
    }

    bool run(audio_chunk& chunk, abort_callback& abort) override {
        try {
            return m_decoder->run(chunk, abort);
        } catch (const exception_io_denied&) {
            // 403 - stream URL likely expired
            if (tryResolveAndReopen(abort)) {
                return m_decoder->run(chunk, abort);
            }
            throw;
        } catch (const exception_io_not_found&) {
            // 404 - track may have been removed
            @autoreleasepool {
                [[JLStreamCache shared] invalidateKey:
                    [NSString stringWithUTF8String:m_path.c_str()]];
                [[JLMetadataCache shared] removeURL:
                    [NSString stringWithUTF8String:m_path.c_str()]];
            }
            throw;
        }
    }

    void seek(double seconds, abort_callback& abort) override {
        try {
            m_decoder->seek(seconds, abort);
        } catch (const exception_io_denied&) {
            if (tryResolveAndReopen(abort)) {
                m_decoder->seek(seconds, abort);
            } else {
                throw;
            }
        }
    }

    bool can_seek() override {
        return m_decoder.is_valid() && m_decoder->can_seek();
    }

private:
    void openUnderlying(abort_callback& abort) {
        input_open_file_helper(m_decoder, m_stream_url.c_str(), abort, m_reason);
    }

    bool tryResolveAndReopen(abort_callback& abort) {
        if (m_reresolutionAttempts >= MAX_RERESOLUTION_ATTEMPTS) {
            console::warning("Cloud Streamer: Max re-resolution attempts exceeded");
            return false;
        }
        m_reresolutionAttempts++;

        @autoreleasepool {
            NSString *nsPath = [NSString stringWithUTF8String:m_path.c_str()];

            // Invalidate old URL
            [[JLStreamCache shared] invalidateKey:nsPath];

            // Get fresh URL
            m_abortFlag = false;
            NSError *error = nil;
            NSString *freshUrl = [[JLStreamResolver shared]
                resolveURLBypassCache:nsPath
                            abortFlag:&m_abortFlag
                                error:&error];

            if (!freshUrl) {
                console::warning("Cloud Streamer: Re-resolution failed");
                return false;
            }

            // Store position before reopening
            double pos = 0;
            try {
                pos = m_decoder->get_position();
            } catch (...) {
                pos = 0;
            }

            // Reopen
            m_stream_url = freshUrl.UTF8String;
            openUnderlying(abort);

            // Seek back to position
            if (pos > 0) {
                m_decoder->seek(pos, abort);
            }

            console::info("Cloud Streamer: Successfully re-resolved expired stream");
            return true;
        }
    }
};
```

### 6.3 Verification
- [ ] Playback works with cached URL
- [ ] Playback works with fresh resolution
- [ ] Abort cancels during open
- [ ] 403 triggers re-resolution
- [ ] Position restored after re-resolution
- [ ] 404 removes from cache

---

## Phase 7: Link Resolver & Metadata

### 7.1 Link Resolver (`Integration/CloudLinkResolver.mm`)
```cpp
class cloud_link_resolver : public link_resolver {
public:
    bool is_our_url(const char* url) override {
        @autoreleasepool {
            return JLIsSupportedURL([NSString stringWithUTF8String:url]);
        }
    }

    bool resolve(const char* url, pfc::string_base& out) override {
        @autoreleasepool {
            NSString *nsUrl = [NSString stringWithUTF8String:url];

            JLCloudURLType type = JLDetectURLType(nsUrl);

            switch (type) {
                case JLCloudURLTypeProfile:
                case JLCloudURLTypePlaylist:
                    console::warning("Cloud Streamer: Profile/playlist URLs not yet supported. "
                                    "Add individual track URLs.");
                    return false;

                case JLCloudURLTypeTrack: {
                    NSString *internal = JLToInternalURL(nsUrl);
                    if (internal) {
                        out = internal.UTF8String;

                        // Trigger prefetch
                        [[JLStreamResolver shared] prefetchURL:internal];

                        return true;
                    }
                    return false;
                }

                default:
                    return false;
            }
        }
    }
};

FB2K_SERVICE_FACTORY(cloud_link_resolver);
```

### 7.2 Metadata in get_info
```cpp
void get_info(file_info& info, abort_callback& abort) override {
    @autoreleasepool {
        NSString *nsPath = [NSString stringWithUTF8String:m_path.c_str()];

        // Try cache first
        JLTrackInfo *track = [[JLMetadataCache shared] trackInfoForURL:nsPath];

        if (!track) {
            // Fetch via yt-dlp
            m_abortFlag = false;
            NSError *error = nil;
            track = [[JLYtDlpWrapper shared]
                extractInfoForURL:JLToWebURL(nsPath)
                        abortFlag:&m_abortFlag
                            error:&error];

            if (track) {
                [[JLMetadataCache shared] setTrackInfo:track forURL:nsPath];
            }
        }

        if (track) {
            if (track.title.length > 0) {
                info.meta_set("title", track.title.UTF8String);
            }
            if (track.uploader.length > 0) {
                info.meta_set("artist", track.uploader.UTF8String);
                info.meta_set("album", track.uploader.UTF8String);
            }
            if (track.duration > 0) {
                info.set_length(track.duration);
            }
            if (track.tags.count > 0) {
                info.meta_set("genre", [track.tags.firstObject UTF8String]);
            }

            // Custom fields
            info.meta_set("CLOUD_SERVICE", track.isMixcloud ? "Mixcloud" : "SoundCloud");
            if (track.trackId.length > 0) {
                info.meta_set("CLOUD_ID", track.trackId.UTF8String);
            }
        }

        // Trigger stream prefetch
        [[JLStreamResolver shared] prefetchURL:nsPath];
    }
}
```

### 7.3 Album Art Extractor
```cpp
class cloud_album_art_extractor : public album_art_extractor {
public:
    bool is_our_path(const char* path, const char* ext) override {
        @autoreleasepool {
            NSString *nsPath = [NSString stringWithUTF8String:path];
            return [nsPath hasPrefix:@"mixcloud://"] ||
                   [nsPath hasPrefix:@"soundcloud://"];
        }
    }

    album_art_data_ptr query(const char* path,
                              const GUID& art_type,
                              abort_callback& abort) override {
        if (art_type != album_art_ids::cover_front) {
            throw exception_album_art_not_found();
        }

        @autoreleasepool {
            NSString *nsPath = [NSString stringWithUTF8String:path];
            JLTrackInfo *track = [[JLMetadataCache shared] trackInfoForURL:nsPath];

            if (!track || !track.thumbnail.length) {
                throw exception_album_art_not_found();
            }

            // Check thumbnail cache
            NSString *localPath = [[JLThumbnailCache shared]
                localPathForThumbnailURL:track.thumbnail];

            if (localPath) {
                NSData *data = [NSData dataWithContentsOfFile:localPath];
                if (data) {
                    return album_art_data_impl::g_create(data.bytes, data.length);
                }
            }

            // Not cached - trigger async download
            [[JLThumbnailCache shared] downloadThumbnailAsync:track.thumbnail
                                                   completion:nil];

            // Return not found for now - will be available on retry
            throw exception_album_art_not_found();
        }
    }
};

FB2K_SERVICE_FACTORY(cloud_album_art_extractor);
```

### 7.4 Verification
- [ ] Link resolver converts URLs
- [ ] Profile URLs show warning
- [ ] Prefetch triggered on URL add
- [ ] Metadata displays in playlist
- [ ] Album art loads async

---

## Phase 8: Preferences UI

### 8.1 Preferences Controller (`UI/CloudPreferences.mm`)
```objc
@interface JLCloudPreferencesController : NSViewController

@property (weak) IBOutlet NSTextField *ytdlpPathField;
@property (weak) IBOutlet NSButton *browseButton;
@property (weak) IBOutlet NSTextField *statusLabel;

@property (weak) IBOutlet NSPopUpButton *mixcloudFormatPopup;
@property (weak) IBOutlet NSPopUpButton *soundcloudFormatPopup;

@property (weak) IBOutlet NSTextField *cacheStatsLabel;
@property (weak) IBOutlet NSButton *clearCacheButton;

@property (weak) IBOutlet NSButton *debugCheckbox;

@end

@implementation JLCloudPreferencesController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self loadSettings];
    [self updateStatus];
}

- (void)loadSettings {
    _ytdlpPathField.stringValue = @(cloud_config::getYtDlpPath().c_str());

    // Set format popups
    [self selectFormat:@(cloud_config::getMixcloudFormat().c_str())
               inPopup:_mixcloudFormatPopup];
    [self selectFormat:@(cloud_config::getSoundCloudFormat().c_str())
               inPopup:_soundcloudFormatPopup];

    _debugCheckbox.state = cloud_config::isDebugEnabled() ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)updateStatus {
    JLYtDlpWrapper *wrapper = [JLYtDlpWrapper shared];

    if ([wrapper isAvailable]) {
        NSString *version = [wrapper version];
        _statusLabel.stringValue = [NSString stringWithFormat:@"yt-dlp %@ (OK)", version];
        _statusLabel.textColor = [NSColor systemGreenColor];
    } else {
        _statusLabel.stringValue = @"yt-dlp not found";
        _statusLabel.textColor = [NSColor systemRedColor];
    }

    // Update cache stats
    NSUInteger metaCount = [[JLMetadataCache shared] count];
    NSUInteger streamCount = [[JLStreamCache shared] count];
    _cacheStatsLabel.stringValue = [NSString stringWithFormat:
        @"Metadata: %lu entries, Stream URLs: %lu cached",
        (unsigned long)metaCount, (unsigned long)streamCount];
}

- (IBAction)browseYtDlp:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;

    if ([panel runModal] == NSModalResponseOK) {
        NSString *path = panel.URL.path;
        _ytdlpPathField.stringValue = path;
        cloud_config::setYtDlpPath(path.UTF8String);
        [[JLYtDlpWrapper shared] setCustomPath:path];
        [self updateStatus];
    }
}

- (IBAction)clearCache:(id)sender {
    [[JLMetadataCache shared] clear];
    [[JLStreamCache shared] cleanupExpired];
    [[JLThumbnailCache shared] clearCache];
    [self updateStatus];
}

- (IBAction)formatChanged:(id)sender {
    if (sender == _mixcloudFormatPopup) {
        cloud_config::setMixcloudFormat(
            _mixcloudFormatPopup.selectedItem.representedObject.UTF8String);
    } else if (sender == _soundcloudFormatPopup) {
        cloud_config::setSoundCloudFormat(
            _soundcloudFormatPopup.selectedItem.representedObject.UTF8String);
    }
}

- (IBAction)debugChanged:(id)sender {
    cloud_config::setDebugEnabled(_debugCheckbox.state == NSControlStateValueOn);
}

@end
```

### 8.2 Preferences Page Registration
```cpp
namespace {
    static const GUID g_guid_prefs =
        {0xe1f2a3b4, 0xc5d6, 0x7e8f, {0x90, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x07}};

    class cloud_preferences_page : public preferences_page {
    public:
        service_ptr instantiate() override {
            @autoreleasepool {
                return fb2k::wrapNSObject(
                    [[JLCloudPreferencesController alloc] init]
                );
            }
        }

        const char* get_name() override {
            return "Cloud Streamer";
        }

        GUID get_guid() override {
            return g_guid_prefs;
        }

        GUID get_parent_guid() override {
            return preferences_page::guid_tools;
        }
    };

    preferences_page_factory_t<cloud_preferences_page> g_prefs_factory;
}
```

### 8.3 Verification
- [ ] Preferences page appears
- [ ] yt-dlp status correct
- [ ] Browse button works
- [ ] Format changes persist
- [ ] Clear cache works
- [ ] Debug toggle works

---

## Phase 9: Main Entry Point

### 9.1 Component Registration (`Integration/Main.mm`)
```objc
#include "../fb2k_sdk.h"
#include "../../../../shared/common_about.h"
#import "../Services/YtDlpWrapper.h"
#import "../Core/MetadataCache.h"
#import "../Core/StreamCache.h"
#import "../UI/CloudPreferences.h"

JL_COMPONENT_ABOUT(
    "Cloud Streamer",
    "1.0.0",
    "Stream Mixcloud and SoundCloud in foobar2000.\n\n"
    "Features:\n"
    "- Direct playback of Mixcloud mixes\n"
    "- Direct playback of SoundCloud tracks\n"
    "- Full seeking support\n"
    "- Metadata and album art display\n"
    "- Persistent caching\n\n"
    "Requires yt-dlp (brew install yt-dlp)"
);

VALIDATE_COMPONENT_FILENAME("foo_jl_cloud_streamer.component");

namespace {

class CloudInitQuit : public initquit {
public:
    void on_init() override {
        @autoreleasepool {
            console::info("[CloudStreamer] Initializing...");

            // Set cache path
            NSString *supportDir = [NSSearchPathForDirectoriesInDomains(
                NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
            NSString *cacheDir = [supportDir stringByAppendingPathComponent:@"foobar2000-v2"];
            NSString *cachePath = [cacheDir stringByAppendingPathComponent:@"jl_cloud_cache.json"];

            [[JLMetadataCache shared] setCachePath:cachePath];
            [[JLMetadataCache shared] loadFromDisk];

            // Check yt-dlp availability
            if ([[JLYtDlpWrapper shared] isAvailable]) {
                NSString *version = [[JLYtDlpWrapper shared] version];
                FB2K_console_formatter() << "[CloudStreamer] yt-dlp " << version.UTF8String << " found";
            } else {
                console::warning("[CloudStreamer] yt-dlp not found - install via: brew install yt-dlp");
            }

            console::info("[CloudStreamer] Initialized");
        }
    }

    void on_quit() override {
        @autoreleasepool {
            console::info("[CloudStreamer] Saving cache...");
            [[JLMetadataCache shared] saveToDisk];
            console::info("[CloudStreamer] Shutdown complete");
        }
    }
};

FB2K_SERVICE_FACTORY(CloudInitQuit);

} // namespace
```

### 9.2 Verification
- [ ] Component loads
- [ ] Initialization message in console
- [ ] yt-dlp status logged
- [ ] Cache saves on quit

---

## Phase 10: Testing & Polish

### 10.1 HLS Verification
Before release, verify HLS support:
```bash
# Get SoundCloud HLS URL
yt-dlp -g -f hls_aac_160k "https://soundcloud.com/track"
# Add the raw HLS URL to foobar2000 playlist
# Verify playback works
```

If HLS doesn't work, implement fallback to `http_mp3_1_0`.

### 10.2 Functional Testing
- [ ] Add Mixcloud URL via paste
- [ ] Add SoundCloud URL via paste
- [ ] Drag-drop from browser
- [ ] Multiple tracks in playlist
- [ ] Sequential playback
- [ ] Shuffle playback
- [ ] Cancel during resolution
- [ ] Long track (3+ hours)

### 10.3 Edge Cases
- [ ] Invalid URL
- [ ] Network error
- [ ] yt-dlp not installed
- [ ] Private/unavailable tracks
- [ ] Geo-restricted content
- [ ] Special characters in track name
- [ ] Very long track title

### 10.4 Performance
- [ ] Initial playback latency <3s
- [ ] No UI freezing
- [ ] Memory usage stable
- [ ] Concurrent track resolution

### 10.5 Documentation
- [ ] README.md complete
- [ ] Installation instructions
- [ ] yt-dlp dependency documented
- [ ] Known limitations listed

---

## Implementation Order (Per Architect Review)

Based on dependencies and risk:

1. **Phase 1**: Project setup
2. **Phase 2**: YtDlpWrapper with abort support (critical foundation)
3. **Phase 3**: Thread-safe caches
4. **Phase 4**: Configuration & URL utils
5. **Phase 5**: StreamResolver with async support
6. **Phase 6**: Input decoder with re-resolution
7. **Phase 7**: Link resolver & metadata
8. **Phase 8**: Preferences UI
9. **Phase 9**: Main entry point
10. **Phase 10**: Testing & polish

---

## Dependencies Summary

| Dependency | Version | Source | Required |
|------------|---------|--------|----------|
| foobar2000 macOS SDK | 2025-03-07 | Bundled | Yes |
| yt-dlp | Latest | Homebrew | Yes |
| Xcode | 15+ | App Store | Development |
