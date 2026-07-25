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
@property (nonatomic, strong) NSMutableArray<NSString *> *imageKeyOrder;  // Insertion order, oldest first (FIFO eviction; hits do not refresh recency)
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *imageBytes;  // Per-key decoded size, for the byte budget
@property (nonatomic, assign) NSUInteger imageStoreBytes;  // Running sum of imageBytes

@property (nonatomic, strong) NSMutableSet<NSString *> *noImageKeys;  // Keys where we tried and found no art
@property (nonatomic, strong) NSMutableArray<NSString *> *noImageKeyOrder;   // Insertion order for FIFO eviction

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
        _imageBytes = [NSMutableDictionary dictionary];
        _imageStoreBytes = 0;
        _maxImageCount = 1000;
        _maxImageBytes = 256 * 1024 * 1024;

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
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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
    });
    return _placeholderImage;
}

- (nullable NSImage *)cachedImageForKey:(NSString *)key {
    // dispatch_assert_queue, not NSAssert: assertions are compiled out in
    // Release, and the image store has no lock behind the convention.
    dispatch_assert_queue(dispatch_get_main_queue());
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

// Decoded footprint of an image: 4 bytes per pixel at its largest
// representation. Art is downscaled to 512 px on load, so this is ~1 MB at
// worst — but the count cap alone would still allow ~1 GB resident.
static NSUInteger EstimatedImageBytes(NSImage *image) {
    NSUInteger widest = 0;
    NSUInteger tallest = 0;
    for (NSImageRep *rep in image.representations) {
        widest = MAX(widest, (NSUInteger)MAX(rep.pixelsWide, 0));
        tallest = MAX(tallest, (NSUInteger)MAX(rep.pixelsHigh, 0));
    }
    if (widest == 0 || tallest == 0) {
        // Vector or size-only representation: fall back to the logical size.
        widest = (NSUInteger)MAX(image.size.width, 1.0);
        tallest = (NSUInteger)MAX(image.size.height, 1.0);
    }
    return widest * tallest * 4;
}

// Insert image into store with FIFO eviction, bounded by BOTH maxImageCount and
// maxImageBytes. Eviction happens only here, on insert — never behind a
// caller's back, which is why this is a plain dictionary and not an NSCache
// (a surprise eviction would blank art that is currently on screen).
// Must be called on main thread (imageStore/imageKeyOrder are main-thread-only).
// Returns NO when the image was rejected: the caller must then blacklist the key,
// or the next draw pass finds it neither cached nor known-bad and decodes it again.
- (BOOL)storeImage:(NSImage *)image forKey:(NSString *)key {
    dispatch_assert_queue(dispatch_get_main_queue());
    if (_imageStore[key]) {
        // Already stored — a re-store counts as a fresh insertion, so move the
        // key to the end of the eviction order (plain cache hits do not).
        [_imageKeyOrder removeObject:key];
        [_imageKeyOrder addObject:key];
        return YES;
    }

    NSUInteger bytes = EstimatedImageBytes(image);

    // One image big enough to need a quarter of the budget would evict most of
    // the cache to make room for itself. Unreachable while loads are downscaled
    // to 512 px (~1 MB); this keeps that an assumption, not a load-bearing one.
    if (bytes > _maxImageBytes / 4) return NO;

    // Work out how many of the oldest entries have to go for both budgets to
    // fit, then remove them in one pass so the order array is compacted once.
    NSUInteger evictCount = 0;
    NSUInteger reclaimed = 0;
    if (_imageKeyOrder.count >= _maxImageCount) {
        evictCount = MAX((NSUInteger)1, _maxImageCount / 10);
        evictCount = MIN(evictCount, _imageKeyOrder.count);
        for (NSUInteger i = 0; i < evictCount; i++) {
            reclaimed += [_imageBytes[_imageKeyOrder[i]] unsignedIntegerValue];
        }
    }
    while (evictCount < _imageKeyOrder.count &&
           (_imageStoreBytes - reclaimed) + bytes > _maxImageBytes) {
        reclaimed += [_imageBytes[_imageKeyOrder[evictCount]] unsignedIntegerValue];
        evictCount++;
    }

    if (evictCount > 0) {
        for (NSUInteger i = 0; i < evictCount; i++) {
            NSString *evictKey = _imageKeyOrder[i];
            [_imageStore removeObjectForKey:evictKey];
            [_imageBytes removeObjectForKey:evictKey];
        }
        [_imageKeyOrder removeObjectsInRange:NSMakeRange(0, evictCount)];
        _imageStoreBytes -= reclaimed;
    }

    _imageStore[key] = image;
    _imageBytes[key] = @(bytes);
    [_imageKeyOrder addObject:key];
    _imageStoreBytes += bytes;
    return YES;
}

- (void)loadImageForKey:(NSString *)key
                 handle:(metadb_handle_ptr)handle
             completion:(void (^)(NSImage * _Nullable image))completion {
    dispatch_assert_queue(dispatch_get_main_queue());

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

                        // stringWithUTF8String: returns nil on invalid UTF-8 in tags
                        NSString *album = (albumStr.length() > 0)
                            ? [NSString stringWithUTF8String:albumStr.get_ptr()] : nil;
                        NSString *artist = (artistStr.length() > 0)
                            ? [NSString stringWithUTF8String:artistStr.get_ptr()] : nil;
                        if (album) {
                            for (NSString *ext in @[@"jpg", @"png", @"jpeg"]) {
                                // %album%.ext  e.g. "().jpg", "Revolver.jpg"
                                NSString *name = [album stringByAppendingPathExtension:ext];
                                if (name) [coverNames addObject:name];
                            }
                            if (artist) {
                                for (NSString *ext in @[@"jpg", @"png", @"jpeg"]) {
                                    // %artist% - %album%.ext  e.g. "Sigur Ros - ().jpg"
                                    NSString *name = [[NSString stringWithFormat:@"%@ - %@", artist, album]
                                                      stringByAppendingPathExtension:ext];
                                    if (name) [coverNames addObject:name];
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
                            // Tag-derived names must stay inside the track's directory:
                            // a "/" or ".." in ALBUM/ARTIST could never match a real
                            // in-directory file anyway, only escape it.
                            if ([name containsString:@"/"] || [name containsString:@".."]) continue;
                            NSString *coverPath = [directory stringByAppendingPathComponent:name];
                            if ([fm fileExistsAtPath:coverPath]) {
                                image = [[NSImage alloc] initWithContentsOfFile:coverPath];
                                if (image) {
                                    image = [self resizeImage:image toMaxSize:512];
                                    break;
                                }
                            }
                        }
                    }
                }
            }
        } @catch (NSException *exception) {
            FB2K_console_formatter() << "[SimPlaylist] Album art file load error: " << (exception.reason.UTF8String ?: "unknown");
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
                            //
                            // Strip "file://" before comparing: fb2k get_path() returns
                            // "file:///Users/..." for local tracks but query_paths() may
                            // return bare POSIX paths ("/Users/..."). mac-volume:// paths
                            // are consistent between get_path() and query_paths() so they
                            // need no adjustment.
                            bool accepted = true;
                            try {
                                album_art_path_list::ptr paths =
                                    instance->query_paths(album_art_ids::cover_front,
                                                          fb2k::noAbort);
                                if (paths.is_valid() && paths->get_count() > 0) {
                                    // Normalise track path: strip file:// scheme prefix.
                                    const char *trackPath = rawPath;
                                    if (strncmp(trackPath, "file://", 7) == 0) trackPath += 7;

                                    const char *lastSlash = strrchr(trackPath, '/');
                                    if (lastSlash) {
                                        size_t dirLen = (size_t)(lastSlash - trackPath) + 1;
                                        accepted = false;
                                        for (t_size i = 0; i < paths->get_count(); i++) {
                                            const char *artPath = paths->get_path(i);
                                            if (strncmp(artPath, "file://", 7) == 0) artPath += 7;
                                            if (strncmp(artPath, trackPath, dirLen) == 0) {
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
                                            if (image) {
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
                FB2K_console_formatter() << "[SimPlaylist] Album art SDK error: " << (exception.reason.UTF8String ?: "unknown");
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

            // A rejected image (too large for the byte budget) must be blacklisted
            // like a missing one, or every redraw re-decodes it.
            BOOL stored = image && [strongSelf storeImage:image forKey:keyCopy];
            if (!stored) {
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
    if (originalSize.width <= 0 || originalSize.height <= 0) {
        return sourceImage;  // Degenerate metadata — nothing sane to render
    }
    // Always render into a fresh bitmap rep, even when no downscale is needed,
    // so the JPEG/PNG decode cost is paid here on the load queue instead of on
    // the main thread at first draw.
    CGFloat scale = MIN(1.0, MIN(maxSize / originalSize.width, maxSize / originalSize.height));

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
    // Allocation can fail on hostile/huge decoded images; passing nil onward
    // would raise on a background queue thread.
    if (!rep) return sourceImage;
    rep.size = newSize;

    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!ctx) {
        [NSGraphicsContext restoreGraphicsState];
        return sourceImage;
    }
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

    NSMutableSet<NSString *> *staleKeys = [NSMutableSet set];
    for (NSString *key in _noImageKeys) {
        if ([key containsString:posixPrefix] ||
                (macVolumePrefix && [key hasPrefix:macVolumePrefix])) {
            [staleKeys addObject:key];
        }
    }

    if (staleKeys.count > 0) {
        [_noImageKeys minusSet:staleKeys];
        // One filtered pass instead of removeObjectsInArray:, which is O(n*m)
        // under the lock on the main thread.
        NSMutableArray<NSString *> *keptOrder =
            [NSMutableArray arrayWithCapacity:_noImageKeyOrder.count];
        for (NSString *key in _noImageKeyOrder) {
            if (![staleKeys containsObject:key]) {
                [keptOrder addObject:key];
            }
        }
        [_noImageKeyOrder setArray:keptOrder];
        FB2K_console_formatter() << "[SimPlaylist] Volume mounted at "
            << mountPath.UTF8String << " — cleared " << (int)staleKeys.count
            << " stale noImageKey(s); cover art will be retried.";
    }

    [_pendingLock unlock];
}

- (void)clearCache {
    dispatch_assert_queue(dispatch_get_main_queue());
    [_imageStore removeAllObjects];
    [_imageKeyOrder removeAllObjects];
    [_imageBytes removeAllObjects];
    _imageStoreBytes = 0;

    [_pendingLock lock];
    [_loadQueue cancelAllOperations];
    [_pendingLoads removeAllObjects];
    [_pendingCompletions removeAllObjects];
    [_noImageKeys removeAllObjects];
    [_noImageKeyOrder removeAllObjects];
    [_pendingLock unlock];
}

@end
