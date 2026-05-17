#import "ArtworkFetcher.h"
#import "../fb2k_sdk.h"

@implementation ArtworkFetcher {
    NSCache<NSString *, NSImage *> *_cache;
    NSMutableSet<NSString *> *_pending;
    dispatch_queue_t _loadQueue;
}

+ (instancetype)sharedFetcher {
    static ArtworkFetcher *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[ArtworkFetcher alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 200;
        _pending = [NSMutableSet set];
        _loadQueue = dispatch_queue_create("com.foobar2000.playvanced.artwork",
                                           DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (nullable NSImage *)cachedImageForPath:(NSString *)path {
    if (!path || path.length == 0) return nil;
    return [_cache objectForKey:path];
}

- (void)fetchArtworkForPath:(NSString *)path completion:(ArtworkCompletion)completion {
    if (!path || path.length == 0) {
        if (completion) completion(nil);
        return;
    }

    NSImage *cached = [_cache objectForKey:path];
    if (cached) {
        if (completion) completion(cached);
        return;
    }

    @synchronized (_pending) {
        if ([_pending containsObject:path]) return;
        [_pending addObject:path];
    }

    NSString *pathCopy = [path copy];

    dispatch_async(_loadQueue, ^{
        @autoreleasepool {
            NSImage *image = [self loadArtForPath:pathCopy];

            @synchronized (self->_pending) {
                [self->_pending removeObject:pathCopy];
            }

            if (image) {
                [self->_cache setObject:image forKey:pathCopy];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(image);
            });
        }
    });
}

- (nullable NSImage *)loadArtForPath:(NSString *)path {
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
        return image;
    } catch (...) {
        return nil;
    }
}

- (void)clearCache {
    [_cache removeAllObjects];
}

+ (NSImage *)placeholderImageOfSize:(CGFloat)size {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [img lockFocus];

    NSRect rect = NSMakeRect(0, 0, size, size);

    NSColor *bgColor = [NSColor colorWithCalibratedWhite:0.15 alpha:1.0];
    [bgColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:rect xRadius:8 yRadius:8] fill];

    NSFont *symbolFont = [NSFont systemFontOfSize:size * 0.3 weight:NSFontWeightUltraLight];
    NSDictionary *attrs = @{
        NSFontAttributeName: symbolFont,
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.4 alpha:1.0],
    };
    NSString *note = @"\u266B";
    NSSize noteSize = [note sizeWithAttributes:attrs];
    NSPoint noteOrigin = NSMakePoint(
        round((size - noteSize.width) / 2.0),
        round((size - noteSize.height) / 2.0)
    );
    [note drawAtPoint:noteOrigin withAttributes:attrs];

    [img unlockFocus];
    return img;
}

@end
