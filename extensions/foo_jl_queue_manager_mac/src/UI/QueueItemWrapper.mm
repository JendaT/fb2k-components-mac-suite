//
//  QueueItemWrapper.mm
//  foo_jl_queue_manager
//
//  Objective-C wrapper for t_playback_queue_item
//

#import "QueueItemWrapper.h"
#include "../Core/QueueOperations.h"
#include "../Core/QueueConfig.h"

@implementation QueueItemWrapper

- (instancetype)initWithQueueItem:(const t_playback_queue_item&)item
                       queueIndex:(NSUInteger)index {
    self = [super init];
    if (self) {
        _handle = item.m_handle;
        _queueIndex = index;

        // Handle orphan items (m_playlist == ~0)
        if (item.m_playlist == queue_config::kOrphanPlaylistIndex) {
            _sourcePlaylist = NSNotFound;
            _sourceItem = NSNotFound;
        } else {
            _sourcePlaylist = item.m_playlist;
            _sourceItem = item.m_item;
        }

        // Cache display values
        [self updateCachedValues];
    }
    return self;
}

- (void)dealloc {
    // metadb_handle_ptr destructor will handle release automatically
    // because it's a C++ member, its destructor is called when the ObjC object is deallocated
}

- (metadb_handle_ptr)handle {
    return _handle;
}

- (BOOL)isOrphan {
    return _sourcePlaylist == NSNotFound;
}

- (BOOL)isValid {
    t_playback_queue_item item;
    item.m_handle = _handle;
    item.m_playlist = [self isOrphan] ? queue_config::kOrphanPlaylistIndex : _sourcePlaylist;
    item.m_item = [self isOrphan] ? queue_config::kOrphanPlaylistIndex : _sourceItem;
    return queue_ops::isItemValid(item);
}

- (NSString*)formatWithPattern:(NSString*)pattern {
    t_playback_queue_item item;
    item.m_handle = _handle;
    pfc::string8 result = queue_ops::formatItem(item, [pattern UTF8String]);
    return [NSString stringWithUTF8String:result.c_str()] ?: @"[Invalid UTF-8]";
}

- (void)updateCachedValues {
    // Cache Artist - Title, pattern from the shared column table
    const queue_config::ColumnInfo* column =
        queue_config::findColumn(queue_config::kColumnArtistTitle);
    _cachedArtistTitle = [self formatWithPattern:@(column->titleFormat)];

    // Cache duration using shared formatting logic
    t_playback_queue_item item;
    item.m_handle = _handle;
    pfc::string8 duration = queue_ops::formatDuration(item);
    _cachedDuration = [NSString stringWithUTF8String:duration.c_str()] ?: @"--:--";
}

@end
