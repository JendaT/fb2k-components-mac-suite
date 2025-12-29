//
//  AlbumArtCache.h
//  foo_simplaylist_mac
//
//  Async album art loading and caching
//

#import <Cocoa/Cocoa.h>
#import "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

@interface AlbumArtCache : NSObject

+ (instancetype)sharedCache;

// Load album art asynchronously
// key: unique identifier (e.g., album path or hash)
// handle: metadb_handle for the track
// completion: called on main thread when image is ready (may be nil for no art)
- (void)loadImageForKey:(NSString *)key
                 handle:(metadb_handle_ptr)handle
             completion:(void (^)(NSImage * _Nullable image))completion;

// Get cached image (returns nil if not cached)
- (nullable NSImage *)cachedImageForKey:(NSString *)key;

// Check if image is being loaded
- (BOOL)isLoadingKey:(NSString *)key;

// Check if we already tried loading this key and found no image
- (BOOL)hasNoImageForKey:(NSString *)key;

// Check if we know this key has an image (survives cache eviction)
- (BOOL)hasKnownImageForKey:(NSString *)key;

// Clear all cached images
- (void)clearCache;

// Set maximum cache size in bytes (default 50MB)
@property (nonatomic, assign) NSUInteger maxCacheSize;

// Get placeholder image for missing art
+ (NSImage *)placeholderImage;

@end

NS_ASSUME_NONNULL_END
