//
//  QueueItemWrapper.mm
//  foo_jl_queue_manager
//
//  Objective-C wrapper for t_playback_queue_item
//

#import "QueueItemWrapper.h"
#include "../Core/QueueOperations.h"

@implementation QueueItemWrapper

- (instancetype)initWithQueueItem:(const t_playback_queue_item&)item
                       queueIndex:(NSUInteger)index {
    self = [super init];
    if (self) {
        _handle = item.m_handle;
        _queueIndex = index;

        // Handle orphan items (m_playlist == ~0)
        if (item.m_playlist == ~(size_t)0) {
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
    if ([self isOrphan]) {
        return YES;  // Orphans are always "valid"
    }

    auto pm = playlist_manager::get();

    // Check playlist exists
    if (_sourcePlaylist >= pm->get_playlist_count()) {
        return NO;
    }

    // Check item index valid
    if (_sourceItem >= pm->playlist_get_item_count(_sourcePlaylist)) {
        return NO;
    }

    // Check handle matches
    metadb_handle_ptr check;
    pm->playlist_get_item_handle(check, _sourcePlaylist, _sourceItem);
    return check == _handle;
}

- (NSString*)formatWithPattern:(NSString*)pattern {
    if (!_handle.is_valid()) {
        return @"[Invalid]";
    }

    try {
        titleformat_object::ptr script;
        titleformat_compiler::get()->compile_safe(script, [pattern UTF8String]);

        pfc::string8 result;
        _handle->format_title(nullptr, result, script, nullptr);

        return [NSString stringWithUTF8String:result.c_str()];
    } catch (...) {
        return @"[Error]";
    }
}

- (void)updateCachedValues {
    // Cache Artist - Title
    _cachedArtistTitle = [self formatWithPattern:@"[%artist% - ]%title%"];

    // Cache duration
    if (_handle.is_valid()) {
        double length = _handle->get_length();
        if (length > 0) {
            int seconds = static_cast<int>(length);
            int minutes = seconds / 60;
            seconds = seconds % 60;

            if (minutes >= 60) {
                int hours = minutes / 60;
                minutes = minutes % 60;
                _cachedDuration = [NSString stringWithFormat:@"%d:%02d:%02d",
                                   hours, minutes, seconds];
            } else {
                _cachedDuration = [NSString stringWithFormat:@"%d:%02d",
                                   minutes, seconds];
            }
        } else {
            _cachedDuration = @"--:--";
        }
    } else {
        _cachedDuration = @"--:--";
    }
}

@end
