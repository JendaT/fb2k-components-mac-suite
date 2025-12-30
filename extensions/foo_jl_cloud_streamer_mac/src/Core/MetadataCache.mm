#import "MetadataCache.h"
#import "CloudConfig.h"
#import "URLUtils.h"

namespace cloud_streamer {

// Keys for serialization
static NSString* const kVersionKey = @"version";
static NSString* const kEntriesKey = @"entries";
static NSString* const kLastAccessKey = @"lastAccess";

// TrackInfo keys
static NSString* const kInternalURLKey = @"internalURL";
static NSString* const kWebURLKey = @"webURL";
static NSString* const kServiceKey = @"service";
static NSString* const kTitleKey = @"title";
static NSString* const kArtistKey = @"artist";
static NSString* const kAlbumKey = @"album";
static NSString* const kUploaderKey = @"uploader";
static NSString* const kDescriptionKey = @"description";
static NSString* const kDurationKey = @"duration";
static NSString* const kThumbnailURLKey = @"thumbnailURL";
static NSString* const kTagsKey = @"tags";
static NSString* const kUploadDateKey = @"uploadDate";

MetadataCache& MetadataCache::shared() {
    static MetadataCache instance;
    return instance;
}

MetadataCache::MetadataCache()
    : m_queue(dispatch_queue_create("com.jl.cloudstreamer.metadatacache", DISPATCH_QUEUE_SERIAL))
    , m_cache([[NSMutableDictionary alloc] init])
    , m_dirty(false)
    , m_saveScheduled(false)
    , m_shutdown(false)
    , m_initialized(false) {
}

MetadataCache::~MetadataCache() {
    shutdown();
}

void MetadataCache::initialize() {
    if (m_initialized) return;

    dispatch_sync(m_queue, ^{
        loadFromDisk();
        m_initialized = true;
    });

    logDebug("MetadataCache initialized with " +
                          std::to_string(m_cache.count) + " entries");
}

void MetadataCache::shutdown() {
    if (m_shutdown) return;
    m_shutdown = true;

    dispatch_sync(m_queue, ^{
        if (m_dirty) {
            saveToDisk();
        }
        [m_cache removeAllObjects];
    });

    logDebug("MetadataCache shutdown complete");
}

NSString* MetadataCache::getCacheFilePath() {
    NSArray<NSString*>* paths = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    NSString* appSupport = paths.firstObject;
    NSString* cacheDir = [appSupport stringByAppendingPathComponent:@"foobar2000-v2/CloudStreamer"];

    // Ensure directory exists
    NSFileManager* fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:cacheDir]) {
        [fm createDirectoryAtPath:cacheDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }

    return [cacheDir stringByAppendingPathComponent:@"metadata_cache.json"];
}

void MetadataCache::loadFromDisk() {
    NSString* path = getCacheFilePath();
    NSFileManager* fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:path]) {
        logDebug("No existing metadata cache file");
        return;
    }

    NSData* data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        logDebug("Failed to read metadata cache file");
        return;
    }

    NSError* error = nil;
    NSDictionary* root = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:&error];
    if (error || ![root isKindOfClass:[NSDictionary class]]) {
        logDebug("Failed to parse metadata cache JSON");
        return;
    }

    migrateIfNeeded(root);

    NSDictionary* entries = root[kEntriesKey];
    if ([entries isKindOfClass:[NSDictionary class]]) {
        [m_cache setDictionary:(NSMutableDictionary*)entries];
    }
}

void MetadataCache::saveToDisk() {
    NSString* path = getCacheFilePath();

    NSDictionary* root = @{
        kVersionKey: @(kCacheVersion),
        kEntriesKey: m_cache
    };

    NSError* error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&error];
    if (error || !data) {
        logDebug("Failed to serialize metadata cache");
        return;
    }

    if ([data writeToFile:path atomically:YES]) {
        m_dirty = false;
        logDebug("Metadata cache saved: " + std::to_string(m_cache.count) + " entries");
    } else {
        logDebug("Failed to write metadata cache file");
    }
}

void MetadataCache::scheduleSave() {
    if (m_saveScheduled || m_shutdown) return;
    m_saveScheduled = true;

    // Delay save by 5 seconds to coalesce multiple writes
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), m_queue, ^{
        m_saveScheduled = false;
        if (m_dirty && !m_shutdown) {
            saveToDisk();
        }
    });
}

void MetadataCache::migrateIfNeeded(NSDictionary* loadedData) {
    NSNumber* version = loadedData[kVersionKey];
    int loadedVersion = version ? version.intValue : 0;

    if (loadedVersion == kCacheVersion) {
        return; // No migration needed
    }

    logDebug("Migrating metadata cache from version " +
                          std::to_string(loadedVersion) + " to " +
                          std::to_string(kCacheVersion));

    // Version 0 -> 1: No schema changes, just set version
    // Future migrations would go here

    m_dirty = true; // Force save with new version
}

void MetadataCache::pruneIfNeeded() {
    if (m_cache.count <= kMaxEntries) return;

    // Sort entries by last access time and remove oldest
    NSMutableArray<NSString*>* sortedKeys = [[m_cache allKeys] mutableCopy];
    [sortedKeys sortUsingComparator:^NSComparisonResult(NSString* key1, NSString* key2) {
        NSDictionary* entry1 = m_cache[key1];
        NSDictionary* entry2 = m_cache[key2];
        NSNumber* access1 = entry1[kLastAccessKey] ?: @0;
        NSNumber* access2 = entry2[kLastAccessKey] ?: @0;
        return [access1 compare:access2];
    }];

    // Remove oldest entries to get back under limit
    size_t toRemove = m_cache.count - kMaxEntries + 100; // Remove extra to avoid frequent pruning
    for (size_t i = 0; i < toRemove && i < sortedKeys.count; i++) {
        [m_cache removeObjectForKey:sortedKeys[i]];
    }

    logDebug("Pruned " + std::to_string(toRemove) + " old metadata entries");
    m_dirty = true;
}

NSDictionary* MetadataCache::trackInfoToDict(const TrackInfo& info) {
    NSMutableDictionary* dict = [[NSMutableDictionary alloc] init];

    dict[kInternalURLKey] = [NSString stringWithUTF8String:info.internalURL.c_str()];
    dict[kWebURLKey] = [NSString stringWithUTF8String:info.webURL.c_str()];
    dict[kServiceKey] = @(static_cast<int>(info.service));
    dict[kTitleKey] = [NSString stringWithUTF8String:info.title.c_str()];
    dict[kArtistKey] = [NSString stringWithUTF8String:info.artist.c_str()];
    dict[kAlbumKey] = [NSString stringWithUTF8String:info.album.c_str()];
    dict[kUploaderKey] = [NSString stringWithUTF8String:info.uploader.c_str()];
    dict[kDescriptionKey] = [NSString stringWithUTF8String:info.description.c_str()];
    dict[kDurationKey] = @(info.duration);
    dict[kThumbnailURLKey] = [NSString stringWithUTF8String:info.thumbnailURL.c_str()];
    dict[kUploadDateKey] = [NSString stringWithUTF8String:info.uploadDate.c_str()];

    // Convert tags vector to NSArray
    NSMutableArray<NSString*>* tagsArray = [[NSMutableArray alloc] init];
    for (const auto& tag : info.tags) {
        [tagsArray addObject:[NSString stringWithUTF8String:tag.c_str()]];
    }
    dict[kTagsKey] = tagsArray;

    // Last access timestamp
    dict[kLastAccessKey] = @([[NSDate date] timeIntervalSince1970]);

    return dict;
}

TrackInfo MetadataCache::dictToTrackInfo(NSDictionary* dict) {
    TrackInfo info;

    NSString* internalURL = dict[kInternalURLKey];
    if (internalURL) info.internalURL = std::string([internalURL UTF8String]);

    NSString* webURL = dict[kWebURLKey];
    if (webURL) info.webURL = std::string([webURL UTF8String]);

    NSNumber* service = dict[kServiceKey];
    if (service) info.service = static_cast<CloudService>(service.intValue);

    NSString* title = dict[kTitleKey];
    if (title) info.title = std::string([title UTF8String]);

    NSString* artist = dict[kArtistKey];
    if (artist) info.artist = std::string([artist UTF8String]);

    NSString* album = dict[kAlbumKey];
    if (album) info.album = std::string([album UTF8String]);

    NSString* uploader = dict[kUploaderKey];
    if (uploader) info.uploader = std::string([uploader UTF8String]);

    NSString* desc = dict[kDescriptionKey];
    if (desc) info.description = std::string([desc UTF8String]);

    NSNumber* duration = dict[kDurationKey];
    if (duration) info.duration = duration.doubleValue;

    NSString* thumbnailURL = dict[kThumbnailURLKey];
    if (thumbnailURL) info.thumbnailURL = std::string([thumbnailURL UTF8String]);

    NSString* uploadDate = dict[kUploadDateKey];
    if (uploadDate) info.uploadDate = std::string([uploadDate UTF8String]);

    NSArray<NSString*>* tags = dict[kTagsKey];
    if (tags) {
        for (NSString* tag in tags) {
            info.tags.push_back(std::string([tag UTF8String]));
        }
    }

    return info;
}

std::optional<TrackInfo> MetadataCache::get(const std::string& internalURL) {
    if (m_shutdown || !m_initialized || internalURL.empty()) {
        return std::nullopt;
    }

    __block std::optional<TrackInfo> result = std::nullopt;
    NSString* key = [NSString stringWithUTF8String:internalURL.c_str()];

    dispatch_sync(m_queue, ^{
        NSDictionary* dict = m_cache[key];
        if (dict) {
            result = dictToTrackInfo(dict);

            // Update last access time
            NSMutableDictionary* updated = [dict mutableCopy];
            updated[kLastAccessKey] = @([[NSDate date] timeIntervalSince1970]);
            m_cache[key] = updated;
            m_dirty = true;
            scheduleSave();
        }
    });

    return result;
}

void MetadataCache::set(const std::string& internalURL, const TrackInfo& info) {
    if (m_shutdown || !m_initialized || internalURL.empty()) {
        return;
    }

    NSString* key = [NSString stringWithUTF8String:internalURL.c_str()];
    NSDictionary* dict = trackInfoToDict(info);

    dispatch_async(m_queue, ^{
        m_cache[key] = dict;
        m_dirty = true;
        pruneIfNeeded();
        scheduleSave();
    });
}

void MetadataCache::remove(const std::string& internalURL) {
    if (m_shutdown || internalURL.empty()) return;

    NSString* key = [NSString stringWithUTF8String:internalURL.c_str()];

    dispatch_async(m_queue, ^{
        [m_cache removeObjectForKey:key];
        m_dirty = true;
        scheduleSave();
    });
}

void MetadataCache::clear() {
    if (m_shutdown) return;

    dispatch_async(m_queue, ^{
        [m_cache removeAllObjects];
        m_dirty = true;
        saveToDisk();
    });

    logDebug("MetadataCache cleared");
}

size_t MetadataCache::size() {
    if (m_shutdown) return 0;

    __block size_t count = 0;
    dispatch_sync(m_queue, ^{
        count = m_cache.count;
    });
    return count;
}

uint64_t MetadataCache::diskUsage() {
    NSString* path = getCacheFilePath();
    NSFileManager* fm = [NSFileManager defaultManager];

    NSDictionary* attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs) {
        return [attrs fileSize];
    }
    return 0;
}

void MetadataCache::flush() {
    if (m_shutdown) return;

    dispatch_sync(m_queue, ^{
        if (m_dirty) {
            saveToDisk();
        }
    });
}

} // namespace cloud_streamer
