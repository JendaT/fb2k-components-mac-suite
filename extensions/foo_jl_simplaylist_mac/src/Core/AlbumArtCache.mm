//
//  AlbumArtCache.mm
//  foo_simplaylist_mac
//

#import "AlbumArtCache.h"

// Maximum entries in key tracking sets (prevents unbounded memory growth)
static const NSUInteger kMaxKeySetSize = 10000;

@interface AlbumArtCache ()
@property (nonatomic, strong) NSCache<NSString *, NSImage *> *imageCache;
@property (nonatomic, strong) NSMutableSet<NSString *> *noImageKeys;  // Keys where we tried and found no art
@property (nonatomic, strong) NSMutableSet<NSString *> *hasImageKeys;  // Keys that have album art
@property (nonatomic, strong) NSMutableArray<NSString *> *noImageKeyOrder;   // LRU order for eviction
@property (nonatomic, strong) NSMutableArray<NSString *> *hasImageKeyOrder;  // LRU order for eviction
@property (nonatomic, strong) NSOperationQueue *loadQueue;
@property (nonatomic, strong) NSMutableSet<NSString *> *pendingLoads;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray *> *pendingCompletions;
@property (nonatomic, strong) NSLock *pendingLock;
@end

@implementation AlbumArtCache

static NSImage *_placeholderImage = nil;

+ (instancetype)sharedCache {
    static AlbumArtCache *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AlbumArtCache alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _imageCache = [[NSCache alloc] init];
        _imageCache.countLimit = 500;  // Max 500 images (increased to reduce eviction during scroll)

        _noImageKeys = [NSMutableSet set];     // Track keys with no album art
        _hasImageKeys = [NSMutableSet set];    // Track keys that have album art
        _noImageKeyOrder = [NSMutableArray array];   // LRU eviction order
        _hasImageKeyOrder = [NSMutableArray array];  // LRU eviction order

        _loadQueue = [[NSOperationQueue alloc] init];
        _loadQueue.maxConcurrentOperationCount = 4;
        _loadQueue.qualityOfService = NSQualityOfServiceUserInitiated;

        _pendingLoads = [NSMutableSet set];
        _pendingCompletions = [NSMutableDictionary dictionary];
        _pendingLock = [[NSLock alloc] init];
        _maxCacheSize = 50 * 1024 * 1024;  // 50MB default
    }
    return self;
}

+ (NSImage *)placeholderImage {
    if (!_placeholderImage) {
        // Create a simple placeholder with music note icon
        NSSize size = NSMakeSize(128, 128);
        _placeholderImage = [[NSImage alloc] initWithSize:size];

        [_placeholderImage lockFocus];

        // Background
        [[NSColor colorWithWhite:0.2 alpha:1.0] setFill];
        NSRectFill(NSMakeRect(0, 0, size.width, size.height));

        // Draw music note symbol
        NSString *musicNote = @"\u266B";  // Musical note
        NSDictionary *attrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:48 weight:NSFontWeightLight],
            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.5 alpha:1.0]
        };
        NSSize textSize = [musicNote sizeWithAttributes:attrs];
        NSPoint point = NSMakePoint((size.width - textSize.width) / 2,
                                    (size.height - textSize.height) / 2);
        [musicNote drawAtPoint:point withAttributes:attrs];

        [_placeholderImage unlockFocus];
    }
    return _placeholderImage;
}

- (nullable NSImage *)cachedImageForKey:(NSString *)key {
    return [_imageCache objectForKey:key];
}

- (BOOL)isLoadingKey:(NSString *)key {
    [_pendingLock lock];
    BOOL loading = [_pendingLoads containsObject:key];
    [_pendingLock unlock];
    return loading;
}

- (BOOL)hasNoImageForKey:(NSString *)key {
    [_pendingLock lock];
    BOOL noImage = [_noImageKeys containsObject:key];
    [_pendingLock unlock];
    return noImage;
}

- (BOOL)hasKnownImageForKey:(NSString *)key {
    [_pendingLock lock];
    BOOL hasImage = [_hasImageKeys containsObject:key];
    [_pendingLock unlock];
    return hasImage;
}

- (void)loadImageForKey:(NSString *)key
                 handle:(metadb_handle_ptr)handle
             completion:(void (^)(NSImage * _Nullable image))completion {

    // Check cache first
    NSImage *cached = [_imageCache objectForKey:key];
    if (cached) {
        if (completion) {
            completion(cached);
        }
        return;
    }

    // Check if we already know there's no image for this key
    [_pendingLock lock];
    if ([_noImageKeys containsObject:key]) {
        [_pendingLock unlock];
        if (completion) {
            completion(nil);
        }
        return;
    }

    // Check if already loading
    if ([_pendingLoads containsObject:key]) {
        // Add completion to pending list
        if (completion) {
            NSMutableArray *completions = _pendingCompletions[key];
            if (!completions) {
                completions = [NSMutableArray array];
                _pendingCompletions[key] = completions;
            }
            [completions addObject:[completion copy]];
        }
        [_pendingLock unlock];
        return;
    }

    // Mark as loading
    [_pendingLoads addObject:key];
    if (completion) {
        _pendingCompletions[key] = [NSMutableArray arrayWithObject:[completion copy]];
    }

    [_pendingLock unlock];

    // Copy handle for use in block
    metadb_handle_ptr handleCopy = handle;
    NSString *keyCopy = [key copy];

    // Add to load queue - process entirely on background thread
    [_loadQueue addOperationWithBlock:^{
        NSImage *image = nil;

        // First try: look for cover image files in the same directory (fast, no SDK needed)
        @try {
            if (handleCopy.is_valid()) {
                const char *path = handleCopy->get_path();
                if (path) {
                    NSString *filePath = [NSString stringWithUTF8String:path];
                    // Remove file:// prefix if present
                    if ([filePath hasPrefix:@"file://"]) {
                        filePath = [filePath substringFromIndex:7];
                        filePath = [filePath stringByRemovingPercentEncoding];
                    }

                    NSString *directory = [filePath stringByDeletingLastPathComponent];
                    NSFileManager *fm = [NSFileManager defaultManager];

                    // Common cover image filenames
                    NSArray *coverNames = @[@"cover.jpg", @"cover.png", @"folder.jpg", @"folder.png",
                                           @"front.jpg", @"front.png", @"album.jpg", @"album.png",
                                           @"Cover.jpg", @"Cover.png", @"Folder.jpg", @"Folder.png"];

                    for (NSString *name in coverNames) {
                        NSString *coverPath = [directory stringByAppendingPathComponent:name];
                        if ([fm fileExistsAtPath:coverPath]) {
                            image = [[NSImage alloc] initWithContentsOfFile:coverPath];
                            if (image) {
                                if (image.size.width > 512 || image.size.height > 512) {
                                    image = [self resizeImage:image toMaxSize:512];
                                }
                                break;
                            }
                        }
                    }
                }
            }
        } @catch (NSException *exception) {
            // Ignore
        }

        // Second try: use SDK (may not work well on background thread)
        if (!image) {
            @try {
                auto art_mgr = album_art_manager_v2::tryGet();
                if (art_mgr.is_valid() && handleCopy.is_valid()) {
                    try {
                        metadb_handle_list items;
                        items.add_item(handleCopy);

                        pfc::list_t<GUID> ids;
                        ids.add_item(album_art_ids::cover_front);

                        album_art_extractor_instance_v2::ptr extractor = art_mgr->open(items, ids, fb2k::noAbort);

                        if (extractor.is_valid()) {
                            album_art_data::ptr data;
                            if (extractor->query(album_art_ids::cover_front, data, fb2k::noAbort)) {
                                if (data.is_valid() && data->size() > 0) {
                                    NSData *imageData = [NSData dataWithBytes:data->data()
                                                                       length:data->size()];
                                    if (imageData) {
                                        image = [[NSImage alloc] initWithData:imageData];
                                        if (image && (image.size.width > 512 || image.size.height > 512)) {
                                            image = [self resizeImage:image toMaxSize:512];
                                        }
                                    }
                                }
                            }
                        }
                    } catch (...) {
                        // Album art not found or other error
                    }
                }
            } @catch (NSException *exception) {
                // Ignore
            }
        }

        // Update cache and call completions on main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_pendingLock lock];
            [self->_pendingLoads removeObject:keyCopy];
            NSArray *completions = [self->_pendingCompletions[keyCopy] copy];
            [self->_pendingCompletions removeObjectForKey:keyCopy];

            if (image) {
                [self->_imageCache setObject:image forKey:keyCopy];
                // Bounded LRU insertion - evict oldest if at capacity
                if (![self->_hasImageKeys containsObject:keyCopy]) {
                    if (self->_hasImageKeys.count >= kMaxKeySetSize) {
                        NSString *oldest = self->_hasImageKeyOrder.firstObject;
                        if (oldest) {
                            [self->_hasImageKeys removeObject:oldest];
                            [self->_hasImageKeyOrder removeObjectAtIndex:0];
                        }
                    }
                    [self->_hasImageKeys addObject:keyCopy];
                    [self->_hasImageKeyOrder addObject:keyCopy];
                }
            } else {
                // Mark this key as having no image to prevent repeated load attempts
                // Bounded LRU insertion - evict oldest if at capacity
                if (![self->_noImageKeys containsObject:keyCopy]) {
                    if (self->_noImageKeys.count >= kMaxKeySetSize) {
                        NSString *oldest = self->_noImageKeyOrder.firstObject;
                        if (oldest) {
                            [self->_noImageKeys removeObject:oldest];
                            [self->_noImageKeyOrder removeObjectAtIndex:0];
                        }
                    }
                    [self->_noImageKeys addObject:keyCopy];
                    [self->_noImageKeyOrder addObject:keyCopy];
                }
            }
            [self->_pendingLock unlock];

            for (void (^block)(NSImage *) in completions) {
                block(image);
            }
        });
    }];
}

- (NSImage *)resizeImage:(NSImage *)sourceImage toMaxSize:(CGFloat)maxSize {
    NSSize originalSize = sourceImage.size;
    CGFloat scale = MIN(maxSize / originalSize.width, maxSize / originalSize.height);

    if (scale >= 1.0) {
        return sourceImage;  // Already small enough
    }

    NSSize newSize = NSMakeSize(originalSize.width * scale, originalSize.height * scale);
    NSImage *resizedImage = [[NSImage alloc] initWithSize:newSize];

    [resizedImage lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [sourceImage drawInRect:NSMakeRect(0, 0, newSize.width, newSize.height)
                   fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0];
    [resizedImage unlockFocus];

    return resizedImage;
}

- (void)clearCache {
    [_imageCache removeAllObjects];

    [_pendingLock lock];
    [_loadQueue cancelAllOperations];
    [_pendingLoads removeAllObjects];
    [_pendingCompletions removeAllObjects];
    [_noImageKeys removeAllObjects];       // Also clear "no image" markers
    [_noImageKeyOrder removeAllObjects];   // Clear LRU order
    [_hasImageKeys removeAllObjects];      // Clear "has image" markers too
    [_hasImageKeyOrder removeAllObjects];  // Clear LRU order
    [_pendingLock unlock];
}

@end
