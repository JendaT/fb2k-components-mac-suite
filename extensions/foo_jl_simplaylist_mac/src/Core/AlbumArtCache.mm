//
//  AlbumArtCache.mm
//  foo_simplaylist_mac
//

#import "AlbumArtCache.h"

// Maximum entries in the no-image tracking set
static const NSUInteger kMaxNoImageKeySetSize = 50000;

@interface AlbumArtCache ()
// Strong image storage — no surprise evictions unlike NSCache
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *imageStore;
@property (nonatomic, strong) NSMutableArray<NSString *> *imageKeyOrder;  // LRU order (oldest first)

@property (nonatomic, strong) NSMutableSet<NSString *> *noImageKeys;  // Keys where we tried and found no art
@property (nonatomic, strong) NSMutableArray<NSString *> *noImageKeyOrder;   // LRU order for eviction

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
        _imageStore = [NSMutableDictionary dictionary];
        _imageKeyOrder = [NSMutableArray array];
        _maxImageCount = 1000;

        _noImageKeys = [NSMutableSet set];
        _noImageKeyOrder = [NSMutableArray array];

        _loadQueue = [[NSOperationQueue alloc] init];
        _loadQueue.maxConcurrentOperationCount = 4;
        _loadQueue.qualityOfService = NSQualityOfServiceUserInitiated;

        _pendingLoads = [NSMutableSet set];
        _pendingCompletions = [NSMutableDictionary dictionary];
        _pendingLock = [[NSLock alloc] init];

        // When a volume mounts, purge any noImageKeys that live under it so that
        // cover art that was missed because the drive wasn't ready (e.g. at startup)
        // is retried on the next draw cycle.
        [[[NSWorkspace sharedWorkspace] notificationCenter]
            addObserver:self
               selector:@selector(volumeDidMount:)
                   name:NSWorkspaceDidMountNotification
                 object:nil];
    }
    return self;
}

+ (NSImage *)placeholderImage {
    if (!_placeholderImage) {
        // Create a simple placeholder with music note icon
        NSSize size = NSMakeSize(128, 128);
        _placeholderImage = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
            // Background
            [[NSColor colorWithWhite:0.2 alpha:1.0] setFill];
            NSRectFill(dstRect);

            // Draw music note symbol
            NSString *musicNote = @"\u266B";
            NSDictionary *attrs = @{
                NSFontAttributeName: [NSFont systemFontOfSize:48 weight:NSFontWeightLight],
                NSForegroundColorAttributeName: [NSColor colorWithWhite:0.5 alpha:1.0]
            };
            NSSize textSize = [musicNote sizeWithAttributes:attrs];
            NSPoint point = NSMakePoint((dstRect.size.width - textSize.width) / 2,
                                        (dstRect.size.height - textSize.height) / 2);
            [musicNote drawAtPoint:point withAttributes:attrs];
            return YES;
        }];
    }
    return _placeholderImage;
}

- (nullable NSImage *)cachedImageForKey:(NSString *)key {
    return _imageStore[key];
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

// Insert image into store with LRU eviction when over maxImageCount.
// Evicts oldest 10% in a batch to amortize the cost.
// Must be called on main thread (imageStore/imageKeyOrder are main-thread-only).
- (void)storeImage:(NSImage *)image forKey:(NSString *)key {
    if (_imageStore[key]) {
        // Already stored — just move to end of LRU order
        [_imageKeyOrder removeObject:key];
        [_imageKeyOrder addObject:key];
        return;
    }

    // Evict oldest entries if at capacity
    if (_imageKeyOrder.count >= _maxImageCount) {
        NSUInteger evictCount = _maxImageCount / 10;
        if (evictCount < 1) evictCount = 1;
        NSArray *toEvict = [_imageKeyOrder subarrayWithRange:NSMakeRange(0, evictCount)];
        for (NSString *evictKey in toEvict) {
            [_imageStore removeObjectForKey:evictKey];
        }
        [_imageKeyOrder removeObjectsInRange:NSMakeRange(0, evictCount)];
    }

    _imageStore[key] = image;
    [_imageKeyOrder addObject:key];
}

- (void)loadImageForKey:(NSString *)key
                 handle:(metadb_handle_ptr)handle
             completion:(void (^)(NSImage * _Nullable image))completion {

    // Check image store first (strong references — no surprise eviction)
    NSImage *cached = _imageStore[key];
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
        @autoreleasepool {
        NSImage *image = nil;

        // First try: look for cover image files in the same directory (fast, no SDK needed)
        @try {
            if (handleCopy.is_valid()) {
                const char *path = handleCopy->get_path();
                if (path) {
                    NSString *filePath = [NSString stringWithUTF8String:path];
                    // Normalise to a POSIX path that NSFileManager understands.
                    // foobar2000 uses file:// for paths on the startup volume and
                    // mac-volume://UUID/... for external volumes. The mac-volume://
                    // UUID is fb2k-internal and does not match any macOS volume UUID
                    // (NSURLVolumeUUIDStringKey, diskutil, IOKit etc.), so we cannot
                    // resolve it here. mac-volume:// paths are handled by the
                    // album_art_manager_v2 fallback below.
                    if ([filePath hasPrefix:@"file://"]) {
                        filePath = [filePath substringFromIndex:7];
                        filePath = [filePath stringByRemovingPercentEncoding];
                    }

                    NSString *directory = [[filePath stringByDeletingLastPathComponent] stringByResolvingSymlinksInPath];
                    NSFileManager *fm = [NSFileManager defaultManager];

                    if (directory.length > 0 && [fm fileExistsAtPath:directory]) {
                        // Build candidate names:
                        // - metadata-driven files (%album%.* and %artist% - %album%.* patterns)
                        // - conventional fallbacks
                        // Using metadata-derived names is *safer* than a hardcoded list since a file named after the
                        // album is far less likely to be a false match in a flat directory full of unrelated files.
                        NSMutableArray<NSString *> *coverNames = [NSMutableArray array];

                        // 1. Metadata-derived candidates
                        pfc::string8 albumStr, artistStr;
                        try {
                            metadb_info_container::ptr infoContainer;
                            if (handleCopy->get_info_ref(infoContainer) && infoContainer.is_valid()) {
                                const file_info &fi = infoContainer->info();
                                const char *album = fi.meta_get("ALBUM", 0);
                                if (album) albumStr = album;
                                const char *artist = fi.meta_get("ARTIST", 0);
                                if (artist) artistStr = artist;
                            }
                        } catch (...) {}

                        if (albumStr.length() > 0) {
                            NSString *album = [NSString stringWithUTF8String:albumStr.get_ptr()];
                            for (NSString *ext in @[@"jpg", @"png", @"jpeg"]) {
                                // %album%.ext  e.g. "().jpg", "Revolver.jpg"
                                [coverNames addObject:[album stringByAppendingPathExtension:ext]];
                            }
                            if (artistStr.length() > 0) {
                                NSString *artist = [NSString stringWithUTF8String:artistStr.get_ptr()];
                                for (NSString *ext in @[@"jpg", @"png", @"jpeg"]) {
                                    // %artist% - %album%.ext  e.g. "Sigur Ros - ().jpg"
                                    NSString *name = [NSString stringWithFormat:@"%@ - %@", artist, album];
                                    [coverNames addObject:[name stringByAppendingPathExtension:ext]];
                                }
                            }
                        }

                        // 2. Conventional fallback names
                        [coverNames addObjectsFromArray:@[
                            @"cover.jpg",  @"cover.png",
                            @"folder.jpg", @"folder.png",
                            @"front.jpg",  @"front.png",
                            @"album.jpg",  @"album.png",
                            @"Cover.jpg",  @"Cover.png",
                            @"Folder.jpg", @"Folder.png"
                        ]];

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
            }
        } @catch (NSException *exception) {
            FB2K_console_formatter() << "[SimPlaylist] Album art file load error: " << exception.reason.UTF8String;
        }

        // Second try: use album_art_manager_v2 which handles all fb2k path schemes
        // natively — including mac-volume://UUID for external volumes — and searches
        // both embedded art and companion files (cover.jpg etc.).
        //
        // Bleed-through guard: album_art_manager_v2 can fall back to library-wide
        // stubs that return art from unrelated tracks. We prevent this by checking
        // that query_paths() reports a source in the same directory as the track.
        // Embedded art (no external path) is always accepted.
        if (!image) {
            @try {
                if (handleCopy.is_valid()) {
                    const char *rawPath = handleCopy->get_path();
                    if (rawPath) {
                        try {
                            auto mgr = album_art_manager_v2::get();
                            metadb_handle_list handleList;
                            handleList.add_item(handleCopy);
                            pfc::list_t<GUID> artIds;
                            artIds.add_item(album_art_ids::cover_front);

                            album_art_extractor_instance_v2::ptr instance =
                                mgr->open(handleList, artIds, fb2k::noAbort);

                            // Bleed-through guard: if the manager found art via an
                            // external file, confirm it lives in the track's directory.
                            bool accepted = true;
                            try {
                                album_art_path_list::ptr paths =
                                    instance->query_paths(album_art_ids::cover_front,
                                                          fb2k::noAbort);
                                if (paths.is_valid() && paths->get_count() > 0) {
                                    // Find the directory prefix of the track's path.
                                    const char *lastSlash = strrchr(rawPath, '/');
                                    if (lastSlash) {
                                        size_t dirLen = (size_t)(lastSlash - rawPath) + 1;
                                        accepted = false;
                                        for (t_size i = 0; i < paths->get_count(); i++) {
                                            if (strncmp(paths->get_path(i), rawPath, dirLen) == 0) {
                                                accepted = true;
                                                break;
                                            }
                                        }
                                    }
                                }
                                // Empty path list → embedded art → no bleed-through risk
                            } catch (...) {
                                accepted = true; // query_paths unavailable → be permissive
                            }

                            if (accepted) {
                                try {
                                    album_art_data::ptr data =
                                        instance->query(album_art_ids::cover_front, fb2k::noAbort);
                                    if (data.is_valid() && data->size() > 0) {
                                        NSData *imageData = [NSData dataWithBytes:data->data()
                                                                           length:data->size()];
                                        if (imageData) {
                                            image = [[NSImage alloc] initWithData:imageData];
                                            if (image && (image.size.width > 512 ||
                                                          image.size.height > 512)) {
                                                image = [self resizeImage:image toMaxSize:512];
                                            }
                                        }
                                    }
                                } catch (...) {
                                    // No art or unsupported format — not an error
                                }
                            }
                        } catch (...) {
                            // Manager unavailable
                        }
                    }
                }
            } @catch (NSException *exception) {
                FB2K_console_formatter() << "[SimPlaylist] Album art SDK error: " << exception.reason.UTF8String;
            }
        }

        // Update cache and call completions on main thread
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            [strongSelf->_pendingLock lock];
            [strongSelf->_pendingLoads removeObject:keyCopy];
            NSArray *completions = [strongSelf->_pendingCompletions[keyCopy] copy];
            [strongSelf->_pendingCompletions removeObjectForKey:keyCopy];

            if (image) {
                [strongSelf storeImage:image forKey:keyCopy];
            } else {
                // Mark this key as having no image to prevent repeated load attempts
                if (![strongSelf->_noImageKeys containsObject:keyCopy]) {
                    if (strongSelf->_noImageKeys.count >= kMaxNoImageKeySetSize) {
                        NSUInteger evictCount = kMaxNoImageKeySetSize / 10;
                        NSArray *toEvict = [strongSelf->_noImageKeyOrder subarrayWithRange:NSMakeRange(0, evictCount)];
                        for (NSString *key in toEvict) {
                            [strongSelf->_noImageKeys removeObject:key];
                        }
                        [strongSelf->_noImageKeyOrder removeObjectsInRange:NSMakeRange(0, evictCount)];
                    }
                    [strongSelf->_noImageKeys addObject:keyCopy];
                    [strongSelf->_noImageKeyOrder addObject:keyCopy];
                }
            }
            [strongSelf->_pendingLock unlock];

            for (void (^block)(NSImage *) in completions) {
                block(image);
            }
        });
        } // @autoreleasepool
    }];
}

- (NSImage *)resizeImage:(NSImage *)sourceImage toMaxSize:(CGFloat)maxSize {
    NSSize originalSize = sourceImage.size;
    CGFloat scale = MIN(maxSize / originalSize.width, maxSize / originalSize.height);

    if (scale >= 1.0) {
        return sourceImage;  // Already small enough
    }

    NSSize newSize = NSMakeSize(round(originalSize.width * scale), round(originalSize.height * scale));

    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)newSize.width
                      pixelsHigh:(NSInteger)newSize.height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    rep.size = newSize;

    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [NSGraphicsContext setCurrentContext:ctx];
    ctx.imageInterpolation = NSImageInterpolationHigh;
    [sourceImage drawInRect:NSMakeRect(0, 0, newSize.width, newSize.height)
                   fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];

    NSImage *resizedImage = [[NSImage alloc] initWithSize:newSize];
    [resizedImage addRepresentation:rep];
    return resizedImage;
}

// Called on the main thread by NSWorkspace when a volume finishes mounting.
// Purges noImageKeys whose path starts with the mount path so that cover art
// that failed to load at startup (drive not yet ready) is retried on the next
// draw cycle instead of staying permanently blacklisted for the session.
- (void)volumeDidMount:(NSNotification *)notification {
    NSURL *mountURL = notification.userInfo[NSWorkspaceVolumeURLKey];
    if (!mountURL) return;

    NSString *mountPath = mountURL.path;
    if (!mountPath.length) return;

    // POSIX prefix for keys stored as "/Volumes/SSD_EVO2/..." or "file:///Volumes/SSD_EVO2/..."
    NSString *posixPrefix = [mountPath hasSuffix:@"/"] ? mountPath : [mountPath stringByAppendingString:@"/"];

    // foobar2000 macOS also uses "mac-volume://UUID/..." paths for external volumes.
    // Fetch the UUID of the newly-mounted volume so we can match those keys too.
    NSString *volumeUUID = nil;
    [mountURL getResourceValue:&volumeUUID forKey:NSURLVolumeUUIDStringKey error:nil];
    NSString *macVolumePrefix = volumeUUID
        ? [NSString stringWithFormat:@"mac-volume://%@/", volumeUUID]
        : nil;

    [_pendingLock lock];

    NSMutableArray<NSString *> *staleKeys = [NSMutableArray array];
    for (NSString *key in _noImageKeys) {
        if ([key containsString:posixPrefix] ||
                (macVolumePrefix && [key hasPrefix:macVolumePrefix])) {
            [staleKeys addObject:key];
        }
    }

    if (staleKeys.count > 0) {
        [_noImageKeys minusSet:[NSSet setWithArray:staleKeys]];
        [_noImageKeyOrder removeObjectsInArray:staleKeys];
        FB2K_console_formatter() << "[SimPlaylist] Volume mounted at "
            << mountPath.UTF8String << " — cleared " << (int)staleKeys.count
            << " stale noImageKey(s); cover art will be retried.";
    }

    [_pendingLock unlock];
}

- (void)clearCache {
    [_imageStore removeAllObjects];
    [_imageKeyOrder removeAllObjects];

    [_pendingLock lock];
    [_loadQueue cancelAllOperations];
    [_pendingLoads removeAllObjects];
    [_pendingCompletions removeAllObjects];
    [_noImageKeys removeAllObjects];
    [_noImageKeyOrder removeAllObjects];
    [_pendingLock unlock];
}

@end
