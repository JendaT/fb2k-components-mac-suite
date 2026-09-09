//
//  AlbumArtCache.h
//  foo_simplaylist_mac
//
//  Async album art loading and caching
//
//  Threading contract: the image store is main-thread-only. loadImageForKey:,
//  cachedImageForKey:, clearCache and completion delivery all run on the main
//  thread; only the decode/resize work happens on the internal load queue.
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

// Clear all cached images
- (void)clearCache;

// Maximum number of images to keep in cache (default 1000)
@property (nonatomic, assign) NSUInteger maxImageCount;

// Maximum decoded bytes to keep in cache (default 256 MB). Enforced alongside
// maxImageCount: whichever budget binds first drives eviction. Without this the
// count cap alone permits ~1 GB resident at 512x512 art.
@property (nonatomic, assign) NSUInteger maxImageBytes;

// Get placeholder image for missing art
+ (NSImage *)placeholderImage;

@end

NS_ASSUME_NONNULL_END
