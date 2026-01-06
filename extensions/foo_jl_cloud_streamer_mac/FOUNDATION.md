# foo_jl_cloud_streamer - Technical Foundation

## Overview

A foobar2000 macOS component that enables streaming Mixcloud and SoundCloud content directly in playlists. Users can treat cloud-based mixes and tracks as virtual library items alongside regular music files.

**Platform**: macOS (foobar2000 v2 for Mac)
**SDK**: foobar2000 macOS SDK (SDK-2025-03-07)
**Development**: Xcode with Objective-C++ (.mm files)
**Output**: `.component` bundle

---

## Architecture

### Core Dependencies

1. **yt-dlp** - Stream URL extraction
   - Subprocess execution via `NSTask`
   - JSON output parsing via `NSJSONSerialization`
   - Handles authentication, geo-restrictions, HLS/DASH
   - User must install separately (Homebrew: `brew install yt-dlp`)

2. **foobar2000 macOS SDK**
   - `input_decoder` for playback
   - `metadb_io_callback_v2` for metadata
   - `link_resolver` for URL handling
   - `preferences_page` for settings

### Project Structure

```
foo_jl_cloud_streamer_mac/
├── foo_jl_cloud_streamer.xcodeproj/
├── Scripts/
│   ├── build.sh
│   ├── install.sh
│   ├── clean.sh
│   └── generate_xcode_project.rb
├── Resources/
│   └── Info.plist
├── src/
│   ├── fb2k_sdk.h              # SDK wrapper
│   ├── Prefix.pch              # Precompiled header
│   ├── Core/
│   │   ├── CloudConfig.h       # Configuration (fb2k::configStore)
│   │   ├── CloudConfig.mm
│   │   ├── TrackInfo.h         # Track metadata struct
│   │   ├── TrackInfo.mm
│   │   ├── URLUtils.h          # URL type detection & conversion
│   │   ├── URLUtils.mm
│   │   ├── StreamCache.h       # Thread-safe URL cache with TTL
│   │   ├── StreamCache.mm
│   │   ├── MetadataCache.h     # Persistent JSON cache
│   │   ├── MetadataCache.mm
│   │   ├── ThumbnailCache.h    # Async album art cache
│   │   └── ThumbnailCache.mm
│   ├── Services/
│   │   ├── YtDlpWrapper.h      # yt-dlp subprocess wrapper
│   │   ├── YtDlpWrapper.mm
│   │   ├── StreamResolver.h    # Async stream resolution
│   │   └── StreamResolver.mm
│   ├── Integration/
│   │   ├── Main.mm             # Component entry point
│   │   ├── CloudInputDecoder.h # input_decoder implementation
│   │   ├── CloudInputDecoder.mm
│   │   ├── CloudLinkResolver.h # link_resolver implementation
│   │   └── CloudLinkResolver.mm
│   └── UI/
│       ├── CloudPreferences.h
│       └── CloudPreferences.mm
├── FOUNDATION.md
├── IMPLEMENTATION_PLAN.md
└── README.md
```

---

## Threading Model

### Thread Context
| Operation | Thread | Notes |
|-----------|--------|-------|
| `input_decoder::open()` | SDK audio thread | Must not block |
| `input_decoder::run()` | SDK audio thread | Must handle stream errors |
| `link_resolver::resolve()` | Main thread | Quick operations only |
| `album_art_extractor::query()` | Background thread | Can be slower |
| yt-dlp subprocess | Dedicated background | Isolated from UI |
| Cache access | Any thread | Must be thread-safe |

### Abort Callback Propagation
All long-running operations must respect `abort_callback`:

```objc
@interface JLYtDlpWrapper : NSObject
- (NSString *)executeWithArguments:(NSArray<NSString *> *)args
                         abortFlag:(std::atomic<bool> *)abort
                           timeout:(NSTimeInterval)timeout
                             error:(NSError **)error;
@end
```

Implementation polls abort flag during subprocess execution:
```objc
while (task.isRunning) {
    if (abort && abort->load()) {
        [task terminate];
        // Wait for termination to complete
        [task waitUntilExit];
        if (error) *error = [NSError errorWithDomain:@"CloudStreamer"
                                                code:JLErrorCancelled
                                            userInfo:@{NSLocalizedDescriptionKey: @"Cancelled"}];
        return nil;
    }
    [NSThread sleepForTimeInterval:0.1];
}
```

### Thread-Safe Cache Access
Caches use dispatch queue isolation:

```objc
@interface JLStreamCache ()
@property (nonatomic, strong) dispatch_queue_t isolationQueue;
@end

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
```

---

## URL Scheme

### Internal URL Format
Custom URL schemes to identify cloud tracks:

```
mixcloud://username/trackname
soundcloud://username/trackname
```

### URL Type Detection
```objc
typedef NS_ENUM(NSInteger, JLCloudURLType) {
    JLCloudURLTypeUnknown,
    JLCloudURLTypeTrack,
    JLCloudURLTypePlaylist,
    JLCloudURLTypeProfile,
};

JLCloudURLType JLDetectURLType(NSString *url);
BOOL JLIsMixcloudURL(NSString *url);
BOOL JLIsSoundCloudURL(NSString *url);
BOOL JLIsSupportedURL(NSString *url);

NSString *JLToInternalURL(NSString *webUrl);
NSString *JLToWebURL(NSString *internalUrl);
```

### Unsupported URL Handling
Profile and playlist URLs are detected but not supported in MVP:
```cpp
bool resolve(const char* url, pfc::string_base& out) override {
    JLCloudURLType type = JLDetectURLType(@(url));
    if (type == JLCloudURLTypeProfile || type == JLCloudURLTypePlaylist) {
        console::warning("Cloud Streamer: Profile/playlist URLs not yet supported. "
                        "Add individual track URLs.");
        return false;
    }
    // ... handle track URLs
}
```

---

## Audio Streaming

### Mixcloud
- **Format**: `http` (direct M4A stream)
- **Codec**: AAC
- **Bitrate**: 64 kbps (service maximum)
- **Seeking**: Full support via HTTP range requests
- **URL TTL**: ~4 hours

### SoundCloud
- **Format**: `hls_aac_160k` (preferred) or `http_mp3_1_0`
- **Codec**: AAC 160kbps or MP3 128kbps
- **Seeking**: Full support
- **URL TTL**: ~2 hours
- **Note**: Higher quality (320kbps) requires Go+ subscription and cookies

### HLS Support Verification
Before implementation, verify HLS support in foobar2000 macOS:
```bash
# Test: Add HLS URL directly to playlist and try playback
# If HLS unsupported, fallback to http_mp3_1_0
```

Fallback logic if HLS not supported:
```objc
- (JLAudioFormat *)bestFormat {
    if (!g_hlsSupported && self.isSoundCloud) {
        for (JLAudioFormat *fmt in self.formats) {
            if ([fmt.formatId hasPrefix:@"http"]) return fmt;
        }
    }
    // ... existing HLS-preferring logic
}
```

### Stream Resolution Flow
```
1. User adds URL to playlist
2. link_resolver converts web URL to internal scheme
3. On playback start, get_info() triggers async prefetch
4. input_decoder::open() checks StreamCache
5. If cache hit: open underlying HTTP decoder immediately
6. If cache miss: async resolution already in progress, wait with abort polling
7. On 403/404 during playback: transparent re-resolution
```

### Stream URL Expiration Recovery
Long DJ mixes may exceed URL TTL. The decoder handles this transparently:

```cpp
bool run(audio_chunk& chunk, abort_callback& abort) override {
    try {
        return m_decoder->run(chunk, abort);
    } catch (const exception_io_denied&) {
        // Stream URL likely expired (403)
        if (tryResolveAndReopen(abort)) {
            return m_decoder->run(chunk, abort);
        }
        throw;
    }
}

bool tryResolveAndReopen(abort_callback& abort) {
    @autoreleasepool {
        // Get fresh stream URL, bypassing cache
        NSError *error = nil;
        NSString *freshUrl = [[JLStreamResolver shared]
            resolveURLBypassCache:m_path abortFlag:&m_abortFlag error:&error];
        if (!freshUrl) return false;

        // Store current position
        double pos = m_decoder->get_position();

        // Reopen with new URL
        m_stream_url = freshUrl.UTF8String;
        input_open_file_helper(m_decoder, m_stream_url.c_str(), abort, m_reason);
        m_decoder->seek(pos, abort);

        return true;
    }
}
```

---

## Metadata Mapping

### yt-dlp Output -> foobar2000 Fields

| yt-dlp field    | foobar2000 field | Notes                    |
|-----------------|------------------|--------------------------|
| `title`         | `%title%`        | Track name               |
| `uploader`      | `%artist%`       | Creator name             |
| `uploader`      | `%album%`        | Also used as album       |
| `description`   | `%comment%`      | Track description        |
| `duration`      | `%length%`       | Seconds as double        |
| `thumbnail`     | album art        | Async fetch, cached      |
| `timestamp`     | `%date%`         | Upload date              |
| `webpage_url`   | `%url%`          | Original URL             |
| `tags[]`        | `%genre%`        | First tag or joined      |

### Custom Fields
```
%cloud_service%   = "Mixcloud" or "SoundCloud"
%cloud_id%        = Unique track ID from service
%cloud_format%    = Format ID (e.g., "http", "hls_aac_160k")
%cloud_error%     = Error message if resolution failed
```

---

## Caching Strategy

### StreamCache (In-Memory, Thread-Safe)
- **Purpose**: Cache resolved stream URLs
- **Storage**: `std::unordered_map` protected by `dispatch_queue_t`
- **TTL**: 4 hours (Mixcloud), 2 hours (SoundCloud)
- **Cleanup**: Lazy on access + periodic timer

```objc
@interface JLStreamCache : NSObject

+ (instancetype)shared;

// Thread-safe access
- (NSString *)streamURLForKey:(NSString *)key;
- (void)setStreamURL:(NSString *)url forKey:(NSString *)key isMixcloud:(BOOL)isMixcloud;
- (void)invalidateKey:(NSString *)key;

// Async prefetch (called from get_info)
- (void)prefetchURLForTrack:(NSString *)trackURL;

// Maintenance
- (void)cleanupExpired;
- (NSUInteger)count;
- (NSUInteger)expiredCount;

@end
```

### MetadataCache (Persistent, Thread-Safe)
- **Purpose**: Cache track metadata to avoid repeated yt-dlp calls
- **Storage**: JSON file in `~/Library/foobar2000-v2/`
- **Freshness**: Optional max-age parameter, background refresh for stale entries
- **Format**:
```json
{
  "version": 1,
  "tracks": {
    "mixcloud://user/track": {
      "info": { /* TrackInfo */ },
      "cached_at": 1703875200
    }
  }
}
```

### Cache Version Migration
```objc
- (BOOL)loadFromDisk {
    NSDictionary *data = [NSJSONSerialization ...];
    NSInteger version = [data[@"version"] integerValue];

    switch (version) {
        case 1: return [self loadV1Data:data];
        // Future: case 2: return [self loadV2Data:data];
        default:
            console::warning("Cloud Streamer: Unknown cache version, resetting");
            [self clear];
            return NO;
    }
}
```

### ThumbnailCache (Async, Disk-Backed)
- **Purpose**: Cache album art to avoid blocking UI
- **Storage**: Disk cache in app support directory
- **Behavior**: Returns cached image immediately, triggers async download on miss

```objc
@interface JLThumbnailCache : NSObject

+ (instancetype)shared;

// Returns local path if cached, nil if not (triggers async download)
- (NSString *)localPathForThumbnailURL:(NSString *)url;

// Async download
- (void)downloadThumbnailAsync:(NSString *)url
                    completion:(void(^)(NSString *localPath, NSError *error))completion;

// Maintenance
- (void)clearCache;
- (NSUInteger)diskUsage;

@end
```

---

## yt-dlp Integration

### Path Resolution with Security Validation
```objc
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

    return nil;  // Not found - do NOT use PATH lookup for security
}

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
```

### Subprocess Execution with Timeout (Zombie-Safe)
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
    __block BOOL timedOut = NO;
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

    // Poll for abort or timeout
    dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(timeout * NSEC_PER_SEC));

    while (!completed) {
        // Check abort flag
        if (abort && abort->load()) {
            [task terminate];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            if (error) *error = [NSError errorWithDomain:@"YtDlp"
                                                    code:JLErrorCancelled
                                                userInfo:@{NSLocalizedDescriptionKey: @"Cancelled"}];
            return nil;
        }

        // Check timeout
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)) == 0) {
            break;  // Task completed
        }

        if (dispatch_time(DISPATCH_TIME_NOW, 0) > deadline) {
            timedOut = YES;
            [task terminate];
            dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
            break;
        }
    }

    if (timedOut) {
        if (error) *error = [NSError errorWithDomain:@"YtDlp"
                                                code:JLErrorTimeout
                                            userInfo:@{NSLocalizedDescriptionKey: @"Timeout"}];
        return nil;
    }

    if (task.terminationStatus != 0) {
        NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];
        NSString *stderrStr = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding];
        if (error) *error = [NSError errorWithDomain:@"YtDlp"
                                                code:task.terminationStatus
                                            userInfo:@{NSLocalizedDescriptionKey: stderrStr ?: @"Unknown error"}];
        return nil;
    }

    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    return [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding];
}
```

### Key Commands

**Extract metadata:**
```bash
yt-dlp -j --no-download "https://mixcloud.com/user/track"
```

**Get stream URL only:**
```bash
yt-dlp -g -f http "https://mixcloud.com/user/track"
```

**List playlist entries:**
```bash
yt-dlp -j --flat-playlist --playlist-end 50 "https://mixcloud.com/user/"
```

---

## Error Handling

### Error Codes
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
```

### yt-dlp Errors
| Exit Code | Meaning                  | Action                      |
|-----------|--------------------------|------------------------------|
| 0         | Success                  | Parse output                |
| 1         | Generic error            | Log, set cloud_error field  |
| 2         | Not available in region  | Set geo-restriction error   |
| Timeout   | Process exceeded 30s     | Kill, show timeout error    |

### Stream Errors
| HTTP Code | Meaning         | Action                        |
|-----------|-----------------|-------------------------------|
| 403       | URL expired     | Transparent re-resolution     |
| 404       | Track removed   | Remove from cache, show error |

### User Feedback Strategy
Errors are communicated via:
1. **Console messages** - For debugging (`console::warning()`)
2. **Metadata field** - `%cloud_error%` visible in playlist if configured
3. **Playback failure** - Standard foobar2000 error handling

```objc
// Set error in metadata for user visibility
info.meta_set("CLOUD_ERROR", "Track unavailable in your region");
```

---

## Configuration Storage

Using `fb2k::configStore` (NOT `cfg_var_legacy` which doesn't persist on macOS):

```objc
// CloudConfig.h
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

// CloudConfig.mm
namespace cloud_config {
    std::string getYtDlpPath() {
        return fb2k::configStore::get()->getString(
            pfc::string8(kPrefix) + "ytdlp_path", "");
    }

    void setYtDlpPath(const std::string& path) {
        fb2k::configStore::get()->setString(
            pfc::string8(kPrefix) + "ytdlp_path", path.c_str());
    }
    // ... etc
}
```

---

## SDK Integration Points

### input_decoder (Non-Blocking)
```cpp
class cloud_input_decoder : public input_decoder {
private:
    service_ptr_t<input_decoder> m_decoder;  // Wrapped HTTP decoder
    pfc::string8 m_path;                      // Original cloud URL
    pfc::string8 m_stream_url;               // Resolved stream URL
    std::atomic<bool> m_abortFlag{false};
    input_open_reason m_reason;

public:
    void open(service_ptr_t<file> filehint,
              const char* path,
              input_open_reason reason,
              abort_callback& abort) override {
        m_path = path;
        m_reason = reason;

        @autoreleasepool {
            NSString *nsPath = [NSString stringWithUTF8String:path];

            // Fast path: check cache first
            NSString *cached = [[JLStreamCache shared] streamURLForKey:nsPath];
            if (cached) {
                m_stream_url = cached.UTF8String;
                input_open_file_helper(m_decoder, m_stream_url.c_str(), abort, reason);
                return;
            }

            // Slow path: resolve with abort support
            m_abortFlag = false;
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
            input_open_file_helper(m_decoder, m_stream_url.c_str(), abort, reason);
        }
    }

    bool run(audio_chunk& chunk, abort_callback& abort) override {
        try {
            return m_decoder->run(chunk, abort);
        } catch (const exception_io_denied&) {
            // Stream URL likely expired
            if (tryResolveAndReopen(abort)) {
                return m_decoder->run(chunk, abort);
            }
            throw;
        }
    }

    void seek(double seconds, abort_callback& abort) override {
        m_decoder->seek(seconds, abort);
    }

    bool can_seek() override {
        return m_decoder->can_seek();
    }

    void on_abort(abort_callback& abort) {
        m_abortFlag = true;
    }

    // ... delegate other methods
};
```

### link_resolver
```cpp
class cloud_link_resolver : public link_resolver {
public:
    bool is_our_url(const char* url) override {
        @autoreleasepool {
            NSString *nsUrl = [NSString stringWithUTF8String:url];
            return JLIsSupportedURL(nsUrl);
        }
    }

    bool resolve(const char* url, pfc::string_base& out) override {
        @autoreleasepool {
            NSString *nsUrl = [NSString stringWithUTF8String:url];

            JLCloudURLType type = JLDetectURLType(nsUrl);
            if (type == JLCloudURLTypeProfile || type == JLCloudURLTypePlaylist) {
                console::warning("Cloud Streamer: Profile/playlist URLs not yet supported. "
                                "Add individual track URLs.");
                return false;
            }

            if (type != JLCloudURLTypeTrack) {
                return false;
            }

            NSString *internal = JLToInternalURL(nsUrl);
            if (internal) {
                out = internal.UTF8String;
                return true;
            }
            return false;
        }
    }
};

FB2K_SERVICE_FACTORY(cloud_link_resolver);
```

### Album Art (Async)
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

            // Check local cache first
            NSString *localPath = [[JLThumbnailCache shared]
                localPathForThumbnailURL:track.thumbnail];

            if (localPath) {
                NSData *data = [NSData dataWithContentsOfFile:localPath];
                if (data) {
                    return album_art_data_impl::g_create(data.bytes, data.length);
                }
            }

            // Not cached - trigger async download and throw not found
            [[JLThumbnailCache shared] downloadThumbnailAsync:track.thumbnail
                                                   completion:nil];
            throw exception_album_art_not_found();
        }
    }
};
```

---

## Preferences

### Configuration Options
- **yt-dlp path** - Custom path with validation status
- **Mixcloud format** - `http` (default)
- **SoundCloud format** - `hls_aac_160k` (default) or `http_mp3_1_0` (fallback)
- **Metadata caching** - Enable/disable persistent cache
- **Debug logging** - Verbose console output

### Preferences UI Elements
- yt-dlp path with browse button
- Status indicator (version, availability, validation)
- Format preferences dropdowns
- Cache management (clear, statistics)
- Debug logging toggle

---

## Build Configuration

### Xcode Settings
- **Deployment Target**: macOS 12.0+ (matches foobar2000 v2)
- **Architectures**: arm64, x86_64 (Universal)
- **Language**: Objective-C++ (.mm)
- **C++ Standard**: C++20

### Frameworks
- Foundation
- AppKit (for preferences UI)

### SDK Include Path
```
$(PROJECT_DIR)/../../../SDK-2025-03-07
```

---

## Testing Checklist

### Playback
- [ ] Mixcloud single track plays
- [ ] SoundCloud single track plays
- [ ] Seeking works correctly
- [ ] Pause/resume works
- [ ] Stop and restart works
- [ ] Multiple tracks in sequence
- [ ] Cancel during stream resolution
- [ ] Long track (>2h) with seek after URL expiry

### Metadata
- [ ] Title displays correctly
- [ ] Artist displays correctly
- [ ] Duration shows in playlist
- [ ] Album art loads (async)
- [ ] Tags map to genre

### URL Handling
- [ ] Web URLs convert to internal scheme
- [ ] Internal URLs convert back to web
- [ ] Mixcloud URLs detected correctly
- [ ] SoundCloud URLs detected correctly
- [ ] Profile URL shows warning message
- [ ] Playlist URL shows warning message
- [ ] Special characters in URL handled

### Error Cases
- [ ] Invalid URL handled gracefully
- [ ] yt-dlp not found shows message
- [ ] Network error shows message
- [ ] Expired stream re-resolves transparently
- [ ] Geo-restricted track shows appropriate error
- [ ] Abort during resolution cancels properly

### Cache
- [ ] Metadata persists across restarts
- [ ] Stream URL cache respects TTL
- [ ] Clear cache works
- [ ] Cache version migration works
- [ ] Thread safety under concurrent access

### Performance
- [ ] Initial playback latency acceptable (<3s)
- [ ] Memory usage reasonable
- [ ] No UI freezing during operations
- [ ] Simultaneous resolution of multiple tracks
- [ ] Resume playback after app restart
