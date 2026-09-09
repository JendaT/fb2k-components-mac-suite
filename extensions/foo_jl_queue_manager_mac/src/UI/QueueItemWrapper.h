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

// Playback state
@property (nonatomic, assign) BOOL isCurrentlyPlaying;
@property (nonatomic, assign) BOOL isPaused;

// Initialize from SDK queue item
- (instancetype)initWithQueueItem:(const t_playback_queue_item&)item
                       queueIndex:(NSUInteger)index;

// Initialize from a raw handle (for the currently playing track not in SDK queue)
- (instancetype)initWithHandle:(metadb_handle_ptr)handle;

// Get the underlying handle (for SDK operations)
- (metadb_handle_ptr)handle;

// Whether this is an orphan item (not from a playlist)
@property (nonatomic, readonly, getter=isOrphan) BOOL orphan;

// Whether the playlist/item references are still valid
@property (nonatomic, readonly, getter=isValid) BOOL valid;

// Format display text using title format pattern
- (NSString*)formatWithPattern:(NSString*)pattern;

@end
