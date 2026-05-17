#import "AlbumArtCache.h"
#import "../fb2k_sdk.h"

@implementation AlbumArtCache {
    NSCache<NSString *, NSImage *> *_cache;
    NSMutableSet<NSString *> *_pending;
    NSMutableSet<NSString *> *_noImageKeys;
    dispatch_queue_t _loadQueue;
}

+ (instancetype)sharedCache {
    static AlbumArtCache *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[AlbumArtCache alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 1000;
        _cache.totalCostLimit = 64 * 1024 * 1024; // ~64MB decoded image budget
        _pending = [NSMutableSet set];
        _noImageKeys = [NSMutableSet set];
        _loadQueue = dispatch_queue_create("com.foobar2000.albumviewvanced.albumart",
                                           DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (nullable NSImage *)imageForPath:(NSString *)path
                              size:(CGFloat)thumbnailSize
                        completion:(nullable AlbumArtCompletion)completion {
    if (!path || path.length == 0) return nil;

    NSString *cacheKey = [NSString stringWithFormat:@"%@_%.0f", path, thumbnailSize];
    NSImage *cached = [_cache objectForKey:cacheKey];
    if (cached) return cached;

    @synchronized (_noImageKeys) {
        if ([_noImageKeys containsObject:cacheKey]) {
            return nil;
        }
    }

    if (!completion) return nil;

    @synchronized (_pending) {
        if ([_pending containsObject:cacheKey]) return nil;
        [_pending addObject:cacheKey];
    }

    NSString *pathCopy = [path copy];
    NSString *keyCopy = [cacheKey copy];
    CGFloat size = thumbnailSize;

    dispatch_async(_loadQueue, ^{
        @autoreleasepool {
            NSImage *image = [self loadArtForPath:pathCopy size:size];

            @synchronized (self->_pending) {
                [self->_pending removeObject:keyCopy];
            }

            if (image) {
                NSSize s = image.size;
                NSUInteger cost = (NSUInteger)MAX(1.0, s.width) * (NSUInteger)MAX(1.0, s.height) * 4;
                [self->_cache setObject:image forKey:keyCopy cost:cost];
            } else {
                @synchronized (self->_noImageKeys) {
                    [self->_noImageKeys addObject:keyCopy];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                completion(image);
            });
        }
    });

    return nil;
}

- (nullable NSImage *)loadArtForPath:(NSString *)path size:(CGFloat)maxSize {
    try {
        auto db = metadb::get();
        metadb_handle_ptr handle = db->handle_create([path UTF8String], 0);
        if (!handle.is_valid()) return nil;

        metadb_handle_list items;
        items.add_item(handle);

        pfc::list_t<GUID> ids;
        ids.add_item(album_art_ids::cover_front);

        abort_callback_dummy abort;
        auto extractor = album_art_manager_v2::get()->open(items, ids, abort);
        if (!extractor.is_valid()) return nil;

        album_art_data_ptr data;
        try {
            data = extractor->query(album_art_ids::cover_front, abort);
        } catch (const exception_album_art_not_found &) {
            return nil;
        }

        if (!data.is_valid() || data->get_size() == 0) return nil;

        NSData *nsData = [NSData dataWithBytes:data->get_ptr() length:data->get_size()];
        NSImage *image = [[NSImage alloc] initWithData:nsData];
        if (!image) return nil;

        NSSize origSize = image.size;
        if (origSize.width <= 0 || origSize.height <= 0) return nil;

        CGFloat scale = MIN(maxSize / origSize.width, maxSize / origSize.height);
        NSSize newSize = NSMakeSize(round(origSize.width * scale), round(origSize.height * scale));

        NSImage *scaled = [[NSImage alloc] initWithSize:newSize];
        [scaled lockFocus];
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [image drawInRect:NSMakeRect(0, 0, newSize.width, newSize.height)
                 fromRect:NSZeroRect
                operation:NSCompositingOperationSourceOver
                 fraction:1.0];
        [scaled unlockFocus];
        return scaled;
    } catch (...) {
        return nil;
    }
}

- (void)clearCache {
    [_cache removeAllObjects];
    @synchronized (_noImageKeys) {
        [_noImageKeys removeAllObjects];
    }
}

+ (NSImage *)placeholderImageOfSize:(CGFloat)size {
    static NSCache<NSNumber *, NSImage *> *placeholderCache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        placeholderCache = [[NSCache alloc] init];
        placeholderCache.countLimit = 16;
    });

    NSNumber *sizeKey = @(llround(size));
    NSImage *cached = [placeholderCache objectForKey:sizeKey];
    if (cached) return cached;

    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [img lockFocus];

    NSRect rect = NSMakeRect(0, 0, size, size);

    // Dark rounded background
    NSColor *bgColor = [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
    [bgColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:6 yRadius:6] fill];

    // Music note symbol
    NSFont *symbolFont = [NSFont systemFontOfSize:size * 0.35 weight:NSFontWeightLight];
    NSDictionary *attrs = @{
        NSFontAttributeName: symbolFont,
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.45 alpha:1.0],
    };
    NSString *note = @"\u266B";
    NSSize noteSize = [note sizeWithAttributes:attrs];
    NSPoint noteOrigin = NSMakePoint(
        round((size - noteSize.width) / 2.0),
        round((size - noteSize.height) / 2.0)
    );
    [note drawAtPoint:noteOrigin withAttributes:attrs];

    [img unlockFocus];
    [placeholderCache setObject:img forKey:sizeKey];
    return img;
}

@end
