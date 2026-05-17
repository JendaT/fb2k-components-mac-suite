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

- (instancetype)initWithHandle:(metadb_handle_ptr)handle {
    self = [super init];
    if (self) {
        _handle = handle;
        _queueIndex = 0;
        _sourcePlaylist = NSNotFound;
        _sourceItem = NSNotFound;
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
    if (!_handle.is_valid()) {
        return @"[Invalid]";
    }

    try {
        titleformat_object::ptr script = queue_ops::getCompiledScript([pattern UTF8String]);

        pfc::string8 result;
        _handle->format_title(nullptr, result, script, nullptr);

        NSString* converted = [NSString stringWithUTF8String:result.c_str()];
        return converted ?: @"[Invalid UTF-8]";
    } catch (const std::exception& e) {
        pfc::string8 msg;
        msg << "[Queue Manager] Title format error: " << e.what();
        console::error(msg);
        return @"[Error]";
    } catch (...) {
        console::error("[Queue Manager] Unknown title format error");
        return @"[Error]";
    }
}

- (void)updateCachedValues {
    // Cache Artist - Title
    _cachedArtistTitle = [self formatWithPattern:@"[%artist% - ]%title%"];

    // Cache duration using shared formatting logic
    t_playback_queue_item item;
    item.m_handle = _handle;
    pfc::string8 duration = queue_ops::formatDuration(item);
    _cachedDuration = [NSString stringWithUTF8String:duration.c_str()] ?: @"--:--";
}

@end
