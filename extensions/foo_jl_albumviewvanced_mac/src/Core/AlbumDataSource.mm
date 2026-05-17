#import "AlbumDataSource.h"
#import "AlbumItem.h"
#import "../fb2k_sdk.h"

@implementation AlbumDataSource {
    NSArray<AlbumItem *> *_albums;
    NSUInteger _totalTrackCount;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _albums = @[];
        _totalTrackCount = 0;
    }
    return self;
}

- (NSArray<AlbumItem *> *)albums {
    return _albums;
}

- (NSUInteger)totalTrackCount {
    return _totalTrackCount;
}

- (void)rebuildWithFilter:(nullable NSString *)filterQuery {
    [_delegate albumDataSourceDidBeginUpdate];

    metadb_handle_list allItems;
    bool gotItems = false;

    @try {
        auto libManager = library_manager::get();
        libManager->get_all_items(allItems);

        if (filterQuery && filterQuery.length > 0) {
            auto searchMgr = search_filter_manager_v2::get();
            search_filter_v2::ptr filter;
            try {
                filter = searchMgr->create_ex(
                    [filterQuery UTF8String],
                    fb2k::service_new<completion_notify_dummy>(),
                    search_filter_manager_v2::KFlagSuppressNotify
                );
            } catch (...) {
                FB2K_console_formatter() << "[AlbumViewVanced] Failed to create search filter";
            }

            if (filter.is_valid()) {
                pfc::array_t<bool> mask;
                mask.set_size(allItems.get_count());
                filter->test_multi(allItems, mask.get_ptr());

                metadb_handle_list filtered;
                for (t_size i = 0; i < allItems.get_count(); i++) {
                    if (mask[i]) filtered.add_item(allItems[i]);
                }
                allItems = filtered;
            }
        }
        gotItems = true;
    } @catch (NSException *ex) {
        FB2K_console_formatter() << "[AlbumViewVanced] Exception fetching library: " << [[ex reason] UTF8String];
    }

    if (!gotItems || allItems.get_count() == 0) {
        _albums = @[];
        _totalTrackCount = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate albumDataSourceDidUpdate];
        });
        return;
    }

    t_size itemCount = allItems.get_count();

    // Capture handles for background thread
    std::vector<metadb_handle_ptr> handles;
    handles.reserve(itemCount);
    for (t_size i = 0; i < itemCount; i++) {
        handles.push_back(allItems[i]);
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSArray<AlbumItem *> *albums = [self buildAlbumsFromHandles:handles];
            NSUInteger totalTracks = 0;
            for (AlbumItem *a in albums) totalTracks += a.trackCount;

            dispatch_async(dispatch_get_main_queue(), ^{
                self->_albums = albums;
                self->_totalTrackCount = totalTracks;
                [self->_delegate albumDataSourceDidUpdate];
            });
        }
    });
}

- (NSArray<AlbumItem *> *)buildAlbumsFromHandles:(const std::vector<metadb_handle_ptr> &)handles {
    titleformat_object_ptr groupFmt, titleFmt, artistFmt, albumFmt, yearFmt, durationFmt, trackNumFmt, ratingFmt;
    static_api_ptr_t<titleformat_compiler> compiler;

    compiler->compile_safe_ex(groupFmt, "%album artist% - %album%");
    compiler->compile_safe_ex(titleFmt, "%title%");
    compiler->compile_safe_ex(artistFmt, "%album artist%");
    compiler->compile_safe_ex(albumFmt, "%album%");
    compiler->compile_safe_ex(yearFmt, "%date%");
    compiler->compile_safe_ex(durationFmt, "%length%");
    compiler->compile_safe_ex(trackNumFmt, "%tracknumber%");
    compiler->compile_safe_ex(ratingFmt, "%rating%");

    NSMutableDictionary<NSString *, AlbumItem *> *albumMap = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *insertionOrder = [NSMutableArray array];

    for (auto &handle : handles) {
        pfc::string8 groupStr, titleStr, artistStr, albumStr, yearStr, durationStr, trackNumStr, ratingStr;
        handle->format_title(nullptr, groupStr, groupFmt, nullptr);
        handle->format_title(nullptr, titleStr, titleFmt, nullptr);
        handle->format_title(nullptr, artistStr, artistFmt, nullptr);
        handle->format_title(nullptr, albumStr, albumFmt, nullptr);
        handle->format_title(nullptr, yearStr, yearFmt, nullptr);
        handle->format_title(nullptr, durationStr, durationFmt, nullptr);
        handle->format_title(nullptr, trackNumStr, trackNumFmt, nullptr);
        handle->format_title(nullptr, ratingStr, ratingFmt, nullptr);

        NSString *key = [NSString stringWithUTF8String:groupStr.c_str()];
        NSString *path = [NSString stringWithUTF8String:handle->get_path()];

        AlbumItem *album = albumMap[key];
        if (!album) {
            album = [[AlbumItem alloc] init];
            album.artistName = [NSString stringWithUTF8String:artistStr.c_str()];
            album.albumName = [NSString stringWithUTF8String:albumStr.c_str()];
            album.year = [NSString stringWithUTF8String:yearStr.c_str()];
            album.artPath = path;
            albumMap[key] = album;
            [insertionOrder addObject:key];
        }

        AlbumTrack *track = [[AlbumTrack alloc] init];
        track.title = [NSString stringWithUTF8String:titleStr.c_str()];
        track.path = path;
        track.duration = [NSString stringWithUTF8String:durationStr.c_str()];
        track.trackNumber = (NSUInteger)atoi(trackNumStr.c_str());
        track.rating = MAX(0, MIN(5, atoi(ratingStr.c_str())));

        [album.tracks addObject:track];
        album.trackCount = album.tracks.count;
    }

    // Sort tracks within each album by track number
    for (NSString *key in insertionOrder) {
        AlbumItem *album = albumMap[key];
        NSInteger ratingTotal = 0;
        NSInteger ratingCount = 0;
        [album.tracks sortUsingComparator:^NSComparisonResult(AlbumTrack *a, AlbumTrack *b) {
            if (a.trackNumber < b.trackNumber) return NSOrderedAscending;
            if (a.trackNumber > b.trackNumber) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        for (AlbumTrack *track in album.tracks) {
            if (track.rating > 0) {
                ratingTotal += track.rating;
                ratingCount++;
            }
        }
        album.rating = ratingCount > 0 ? (NSInteger)llround((double)ratingTotal / (double)ratingCount) : 0;
    }

    // Sort albums by artist then album name
    [insertionOrder sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a localizedCaseInsensitiveCompare:b];
    }];

    NSMutableArray<AlbumItem *> *result = [NSMutableArray arrayWithCapacity:insertionOrder.count];
    for (NSString *key in insertionOrder) {
        [result addObject:albumMap[key]];
    }
    return result;
}

@end
