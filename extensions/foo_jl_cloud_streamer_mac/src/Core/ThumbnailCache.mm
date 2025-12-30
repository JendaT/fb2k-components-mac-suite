#import "ThumbnailCache.h"
#import "CloudConfig.h"
#import <CommonCrypto/CommonDigest.h>

namespace cloud_streamer {

ThumbnailCache& ThumbnailCache::shared() {
    static ThumbnailCache instance;
    return instance;
}

ThumbnailCache::ThumbnailCache()
    : m_queue(dispatch_queue_create("com.jl.cloudstreamer.thumbnailcache", DISPATCH_QUEUE_SERIAL))
    , m_session(nil)
    , m_pendingCallbacks([[NSMutableDictionary alloc] init])
    , m_shutdown(false)
    , m_initialized(false) {
}

ThumbnailCache::~ThumbnailCache() {
    shutdown();
}

void ThumbnailCache::initialize() {
    if (m_initialized) return;

    dispatch_sync(m_queue, ^{
        // Create URL session with reasonable timeout
        NSURLSessionConfiguration* config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;
        config.timeoutIntervalForResource = 60.0;
        m_session = [NSURLSession sessionWithConfiguration:config];

        // Ensure cache directory exists
        getCacheDirectory();

        m_initialized = true;
    });

    logDebug("ThumbnailCache initialized");
}

void ThumbnailCache::shutdown() {
    if (m_shutdown) return;
    m_shutdown = true;

    dispatch_sync(m_queue, ^{
        [m_session invalidateAndCancel];
        m_session = nil;
        [m_pendingCallbacks removeAllObjects];
    });

    logDebug("ThumbnailCache shutdown complete");
}

NSString* ThumbnailCache::getCacheDirectory() {
    NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(
        NSCachesDirectory, NSUserDomainMask, YES);
    NSString* cacheBase = paths.firstObject;
    NSString* cacheDir = [cacheBase stringByAppendingPathComponent:@"com.foobar2000.CloudStreamer/thumbnails"];

    NSFileManager* fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:cacheDir]) {
        [fm createDirectoryAtPath:cacheDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }

    return cacheDir;
}

NSString* ThumbnailCache::cacheFileNameForURL(const std::string& url) {
    // Create SHA256 hash of URL for unique filename
    NSString* urlString = [NSString stringWithUTF8String:url.c_str()];
    NSData* urlData = [urlString dataUsingEncoding:NSUTF8StringEncoding];

    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(urlData.bytes, (CC_LONG)urlData.length, hash);

    NSMutableString* hashString = [[NSMutableString alloc] init];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hashString appendFormat:@"%02x", hash[i]];
    }

    // Extract extension from URL if present
    NSString* extension = @"jpg"; // Default
    NSString* lowercaseURL = [urlString lowercaseString];
    if ([lowercaseURL containsString:@".png"]) {
        extension = @"png";
    } else if ([lowercaseURL containsString:@".webp"]) {
        extension = @"webp";
    } else if ([lowercaseURL containsString:@".gif"]) {
        extension = @"gif";
    }

    return [NSString stringWithFormat:@"%@.%@", hashString, extension];
}

NSString* ThumbnailCache::cachePathForURL(const std::string& url) {
    NSString* cacheDir = getCacheDirectory();
    NSString* fileName = cacheFileNameForURL(url);
    return [cacheDir stringByAppendingPathComponent:fileName];
}

std::optional<std::string> ThumbnailCache::getCachedPath(const std::string& thumbnailURL) {
    if (m_shutdown || !m_initialized || thumbnailURL.empty()) {
        return std::nullopt;
    }

    NSString* cachePath = cachePathForURL(thumbnailURL);
    NSFileManager* fm = [NSFileManager defaultManager];

    if ([fm fileExistsAtPath:cachePath]) {
        // Check if file is not too old
        NSDictionary* attrs = [fm attributesOfItemAtPath:cachePath error:nil];
        if (attrs) {
            NSDate* modDate = attrs[NSFileModificationDate];
            NSTimeInterval age = -[modDate timeIntervalSinceNow];
            if (age < kMaxAgeDays * 24 * 60 * 60) {
                return std::string([cachePath UTF8String]);
            }
            // Too old, remove it
            [fm removeItemAtPath:cachePath error:nil];
        }
    }

    return std::nullopt;
}

void ThumbnailCache::fetch(const std::string& thumbnailURL, ThumbnailCallback callback) {
    if (m_shutdown || !m_initialized || thumbnailURL.empty()) {
        ThumbnailResult result;
        result.success = false;
        result.errorMessage = "Cache not initialized or invalid URL";
        callback(result);
        return;
    }

    // Check cache first
    auto cachedPath = getCachedPath(thumbnailURL);
    if (cachedPath.has_value()) {
        ThumbnailResult result;
        result.success = true;
        result.filePath = cachedPath.value();
        callback(result);
        return;
    }

    NSString* cachePath = cachePathForURL(thumbnailURL);
    downloadThumbnail(thumbnailURL, cachePath, callback, false);
}

void ThumbnailCache::fetchData(const std::string& thumbnailURL, ThumbnailCallback callback) {
    if (m_shutdown || !m_initialized || thumbnailURL.empty()) {
        ThumbnailResult result;
        result.success = false;
        result.errorMessage = "Cache not initialized or invalid URL";
        callback(result);
        return;
    }

    // Check cache first
    auto cachedPath = getCachedPath(thumbnailURL);
    if (cachedPath.has_value()) {
        NSString* path = [NSString stringWithUTF8String:cachedPath.value().c_str()];
        NSData* data = [NSData dataWithContentsOfFile:path];
        if (data) {
            ThumbnailResult result;
            result.success = true;
            result.filePath = cachedPath.value();
            result.imageData = data;
            callback(result);
            return;
        }
    }

    NSString* cachePath = cachePathForURL(thumbnailURL);
    downloadThumbnail(thumbnailURL, cachePath, callback, true);
}

void ThumbnailCache::downloadThumbnail(const std::string& url,
                                        NSString* cachePath,
                                        ThumbnailCallback callback,
                                        bool returnData) {
    NSString* urlKey = [NSString stringWithUTF8String:url.c_str()];

    // Coalesce multiple requests for the same URL
    dispatch_async(m_queue, ^{
        // Wrap callback info
        NSDictionary* callbackInfo = @{
            @"callback": [^(const ThumbnailResult& r) { callback(r); } copy],
            @"returnData": @(returnData)
        };

        NSMutableArray* pending = m_pendingCallbacks[urlKey];
        if (pending) {
            // Already downloading, add to pending list
            [pending addObject:callbackInfo];
            return;
        }

        // Start new download
        pending = [[NSMutableArray alloc] initWithObjects:callbackInfo, nil];
        m_pendingCallbacks[urlKey] = pending;

        NSURL* nsurl = [NSURL URLWithString:urlKey];
        if (!nsurl) {
            ThumbnailResult result;
            result.success = false;
            result.errorMessage = "Invalid URL";

            for (NSDictionary* info in pending) {
                void (^cb)(const ThumbnailResult&) = info[@"callback"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    cb(result);
                });
            }
            [m_pendingCallbacks removeObjectForKey:urlKey];
            return;
        }

        NSURLSessionDataTask* task = [m_session dataTaskWithURL:nsurl
            completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                dispatch_async(m_queue, ^{
                    NSMutableArray* callbacks = m_pendingCallbacks[urlKey];
                    [m_pendingCallbacks removeObjectForKey:urlKey];

                    ThumbnailResult result;

                    if (error || !data) {
                        result.success = false;
                        result.errorMessage = error ? std::string([[error localizedDescription] UTF8String]) : "No data received";
                    } else {
                        // Verify it's an image
                        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
                        NSString* contentType = httpResponse.allHeaderFields[@"Content-Type"];
                        if (contentType && ![contentType containsString:@"image"]) {
                            result.success = false;
                            result.errorMessage = "Response is not an image";
                        } else {
                            // Save to cache
                            if ([data writeToFile:cachePath atomically:YES]) {
                                result.success = true;
                                result.filePath = std::string([cachePath UTF8String]);
                                result.imageData = data;
                                if (contentType) {
                                    result.mimeType = std::string([contentType UTF8String]);
                                }
                                logDebug("Thumbnail cached: " + url);
                            } else {
                                result.success = false;
                                result.errorMessage = "Failed to write cache file";
                            }
                        }
                    }

                    // Call all pending callbacks
                    for (NSDictionary* info in callbacks) {
                        void (^cb)(const ThumbnailResult&) = info[@"callback"];
                        BOOL wantsData = [info[@"returnData"] boolValue];

                        ThumbnailResult cbResult = result;
                        if (!wantsData) {
                            cbResult.imageData = nil; // Don't pass data if not requested
                        }

                        dispatch_async(dispatch_get_main_queue(), ^{
                            cb(cbResult);
                        });
                    }
                });
            }];

        [task resume];
    });
}

void ThumbnailCache::remove(const std::string& thumbnailURL) {
    if (m_shutdown || thumbnailURL.empty()) return;

    NSString* cachePath = cachePathForURL(thumbnailURL);
    NSFileManager* fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:cachePath error:nil];
}

void ThumbnailCache::clear() {
    if (m_shutdown) return;

    dispatch_async(m_queue, ^{
        NSString* cacheDir = getCacheDirectory();
        NSFileManager* fm = [NSFileManager defaultManager];

        NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:cacheDir error:nil];
        for (NSString* file in files) {
            NSString* path = [cacheDir stringByAppendingPathComponent:file];
            [fm removeItemAtPath:path error:nil];
        }
    });

    logDebug("ThumbnailCache cleared");
}

void ThumbnailCache::prune() {
    if (m_shutdown || !m_initialized) return;

    dispatch_async(m_queue, ^{
        NSString* cacheDir = getCacheDirectory();
        NSFileManager* fm = [NSFileManager defaultManager];

        NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:cacheDir error:nil];
        if (!files || files.count == 0) return;

        // Collect file info
        NSMutableArray<NSDictionary*>* fileInfos = [[NSMutableArray alloc] init];
        uint64_t totalSize = 0;
        NSDate* cutoffDate = [NSDate dateWithTimeIntervalSinceNow:-(kMaxAgeDays * 24 * 60 * 60)];

        for (NSString* file in files) {
            NSString* path = [cacheDir stringByAppendingPathComponent:file];
            NSDictionary* attrs = [fm attributesOfItemAtPath:path error:nil];
            if (!attrs) continue;

            NSDate* modDate = attrs[NSFileModificationDate];
            uint64_t fileSize = [attrs fileSize];
            totalSize += fileSize;

            // Remove files older than max age
            if ([modDate compare:cutoffDate] == NSOrderedAscending) {
                [fm removeItemAtPath:path error:nil];
                totalSize -= fileSize;
                continue;
            }

            [fileInfos addObject:@{
                @"path": path,
                @"date": modDate,
                @"size": @(fileSize)
            }];
        }

        // If still over size limit, remove oldest files
        if (totalSize > kMaxCacheSize) {
            [fileInfos sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
                return [a[@"date"] compare:b[@"date"]];
            }];

            for (NSDictionary* info in fileInfos) {
                if (totalSize <= kMaxCacheSize * 0.8) break; // Leave 20% headroom

                NSString* path = info[@"path"];
                uint64_t fileSize = [info[@"size"] unsignedLongLongValue];
                [fm removeItemAtPath:path error:nil];
                totalSize -= fileSize;
            }
        }

        logDebug("ThumbnailCache pruned, size: " +
                              std::to_string(totalSize / 1024 / 1024) + " MB");
    });
}

size_t ThumbnailCache::entryCount() {
    if (m_shutdown) return 0;

    NSString* cacheDir = getCacheDirectory();
    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:cacheDir error:nil];
    return files ? files.count : 0;
}

uint64_t ThumbnailCache::diskUsage() {
    if (m_shutdown) return 0;

    NSString* cacheDir = getCacheDirectory();
    NSFileManager* fm = [NSFileManager defaultManager];
    NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:cacheDir error:nil];

    uint64_t totalSize = 0;
    for (NSString* file in files) {
        NSString* path = [cacheDir stringByAppendingPathComponent:file];
        NSDictionary* attrs = [fm attributesOfItemAtPath:path error:nil];
        if (attrs) {
            totalSize += [attrs fileSize];
        }
    }

    return totalSize;
}

} // namespace cloud_streamer
