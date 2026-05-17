//
//  LibraryAlbumArtCache.mm
//  foo_jl_libvanced
//

#import "LibraryAlbumArtCache.h"
#import "../fb2k_sdk.h"

@implementation LibraryAlbumArtCache {
    NSCache<NSString *, NSImage *> *_cache;
    NSMutableSet<NSString *> *_pendingPaths;
    dispatch_queue_t _loadQueue;
}

+ (instancetype)sharedCache {
    static LibraryAlbumArtCache *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LibraryAlbumArtCache alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [[NSCache alloc] init];
        _cache.countLimit = 500;
        _pendingPaths = [NSMutableSet set];
        _loadQueue = dispatch_queue_create("com.foobar2000.libvanced.albumart",
                                           DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (nullable NSImage *)imageForPath:(NSString *)path
                        completion:(nullable AlbumArtCompletionBlock)completion {
    if (!path || path.length == 0) return nil;

    NSImage *cached = [_cache objectForKey:path];
    if (cached) return cached;

    if (!completion) return nil;

    @synchronized (_pendingPaths) {
        if ([_pendingPaths containsObject:path]) return nil;
        [_pendingPaths addObject:path];
    }

    NSString *pathCopy = [path copy];
    dispatch_async(_loadQueue, ^{
        @autoreleasepool {
            NSImage *image = [self loadAlbumArtForPath:pathCopy];

            @synchronized (self->_pendingPaths) {
                [self->_pendingPaths removeObject:pathCopy];
            }

            if (image) {
                [self->_cache setObject:image forKey:pathCopy];
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                completion(image);
            });
        }
    });

    return nil;
}

- (nullable NSImage *)loadAlbumArtForPath:(NSString *)path {
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

        NSData *nsData = [NSData dataWithBytes:data->get_ptr()
                                        length:data->get_size()];
        NSImage *image = [[NSImage alloc] initWithData:nsData];

        // Scale down for tree display
        if (image) {
            CGFloat maxSize = 64.0;
            NSSize size = image.size;
            if (size.width > maxSize || size.height > maxSize) {
                CGFloat scale = MIN(maxSize / size.width, maxSize / size.height);
                NSSize newSize = NSMakeSize(size.width * scale, size.height * scale);
                NSImage *scaled = [[NSImage alloc] initWithSize:newSize];
                [scaled lockFocus];
                [image drawInRect:NSMakeRect(0, 0, newSize.width, newSize.height)];
                [scaled unlockFocus];
                return scaled;
            }
        }

        return image;
    } catch (...) {
        return nil;
    }
}

- (void)clearCache {
    [_cache removeAllObjects];
}

@end
