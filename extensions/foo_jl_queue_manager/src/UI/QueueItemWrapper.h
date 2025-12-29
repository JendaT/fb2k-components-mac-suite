//
//  QueueItemWrapper.h
//  foo_jl_queue_manager
//
//  Objective-C wrapper for t_playback_queue_item
//  CRITICAL: Uses C++ member for metadb_handle_ptr, NOT ObjC property
//

#pragma once

#import <Cocoa/Cocoa.h>
#include <foobar2000/SDK/foobar2000.h>

@interface QueueItemWrapper : NSObject {
    // CRITICAL: C++ member variable, not ObjC property
    // ObjC properties with 'assign' will cause memory corruption for smart pointers
    metadb_handle_ptr _handle;
}

// Queue position (0-based index in queue)
@property (nonatomic, readonly) NSUInteger queueIndex;

// Source playlist index (or NSNotFound for orphan items)
@property (nonatomic, readonly) NSUInteger sourcePlaylist;

// Source item index within playlist (or NSNotFound for orphan items)
@property (nonatomic, readonly) NSUInteger sourceItem;

// Cached display text for Artist - Title column
@property (nonatomic, strong) NSString* cachedArtistTitle;

// Cached duration string
@property (nonatomic, strong) NSString* cachedDuration;

// Initialize from SDK queue item
- (instancetype)initWithQueueItem:(const t_playback_queue_item&)item
                       queueIndex:(NSUInteger)index;

// Get the underlying handle (for SDK operations)
- (metadb_handle_ptr)handle;

// Check if this is an orphan item (not from a playlist)
- (BOOL)isOrphan;

// Check if the playlist/item references are still valid
- (BOOL)isValid;

// Format display text using title format pattern
- (NSString*)formatWithPattern:(NSString*)pattern;

@end
