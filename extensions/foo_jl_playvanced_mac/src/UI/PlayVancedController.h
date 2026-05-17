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

@end

NS_ASSUME_NONNULL_END
