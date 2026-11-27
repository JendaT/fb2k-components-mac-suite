#pragma once

#import <Cocoa/Cocoa.h>
#include "../fb2k_sdk.h"

NS_ASSUME_NONNULL_BEGIN

@interface PlayVancedController : NSViewController

- (void)handleNewTrack:(metadb_handle_ptr)track;
- (void)handlePlaybackStop;
- (void)handlePlaybackPause:(BOOL)paused;
- (void)handlePlaybackTime:(double)time;
- (void)handlePlaybackSeek:(double)time;
- (void)handleSelectionChanged;
- (void)handleVolumeChanged:(float)volume;
- (void)handlePlaybackOrderChanged:(NSInteger)order;
// Now Playing / playing playlist / playback queue changed (refreshes Up Next if shown).
- (void)handleUpNextChanged;
// Play Next / Add to Queue inserted `count` tracks into Now Playing.
- (void)handleUpNextItemsAdded:(NSUInteger)count playNext:(BOOL)playNext;

// Actions shared by the bar buttons and the keyboard shortcuts.
- (void)toggleShuffle;
- (void)cycleRepeat;
- (void)toggleUpNextPopover;

// YES if `window` hosts this bar or its Up Next popover.
- (BOOL)ownsWindow:(nullable NSWindow *)window;

@end

NS_ASSUME_NONNULL_END
